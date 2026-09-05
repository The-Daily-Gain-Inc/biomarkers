import Foundation
import SwiftData
import CryptoKit
import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore

/// Mirrors the local SwiftData stores to Firestore under an anonymous user so
/// everything survives a phone wipe and can restore on a fresh install.
/// Strategy: restore (merge cloud → local) on launch, then back up
/// (local → cloud). Records are keyed by their stable ids; last write wins.
@MainActor
final class CloudSync: ObservableObject {
    @Published var isSignedIn = false
    @Published var isSyncing = false
    @Published var isAnonymous = true
    /// True once the launch restore has finished (or been attempted), so local
    /// seeding won't run over data that's still arriving from the cloud.
    @Published var didRestore = false
    /// True after the launch bootstrap seeds — signals views to refresh.
    @Published var bootstrapDone = false
    @Published var lastBackup: Date?
    @Published var lastError: String?
    /// When the last restore (full or incremental) started — the cutoff for
    /// the next incremental pull.
    private(set) var lastRestore: Date?

    /// True only when the most recent restore actually reached Firestore (vs
    /// failed offline). Seeding must never run on an unconfirmed restore, or a
    /// 2nd device would clobber cloud data that simply hadn't arrived yet.
    private(set) var restoreSucceeded = false
    /// Whether the cloud collection was confirmed EMPTY for this account on the
    /// last restore — the precondition for (re)seeding it from the bundle.
    private(set) var cloudRetroWasEmpty = false
    private(set) var cloudWorkoutsWasEmpty = false
    private(set) var cloudDailyMetricsWasEmpty = false
    /// Per-account migration/seed flags, loaded from users/{uid}/meta/flags.
    /// Kept per-account (not per-device) so a 2nd device never re-forces a
    /// migration already applied to the account.
    private var accountFlags: [String: Bool] = [:]

    private var uid: String?
    private var currentNonce: String?
    private var pendingBackup: Task<Void, Never>?
    private var db: Firestore { Firestore.firestore() }

    init() {
        if let ts = UserDefaults.standard.object(forKey: "cloud.lastBackup") as? Double {
            lastBackup = Date(timeIntervalSince1970: ts)
        }
        if let ts = UserDefaults.standard.object(forKey: "cloud.lastRestore") as? Double {
            lastRestore = Date(timeIntervalSince1970: ts)
        }
    }

    /// Signs in anonymously (stable per install) so data is scoped to the user.
    func signIn() async {
        if let user = Auth.auth().currentUser {
            uid = user.uid; isSignedIn = true; isAnonymous = user.isAnonymous; return
        }
        do {
            let result = try await Auth.auth().signInAnonymously()
            uid = result.user.uid
            isSignedIn = true
            isAnonymous = true
        } catch {
            lastError = "Cloud sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Sign in with Apple

    /// Configure the Apple ID request with a fresh nonce.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Complete Apple sign-in: link to the anonymous user (keeping the same
    /// uid + data) when possible, otherwise sign in to the existing account.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>, context: ModelContext) async {
        switch result {
        case .failure(let error):
            lastError = "Apple sign-in cancelled: \(error.localizedDescription)"
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                lastError = "Apple sign-in: missing token."
                return
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken, rawNonce: nonce, fullName: credential.fullName)
            do {
                if let user = Auth.auth().currentUser, user.isAnonymous {
                    let linked = try await user.link(with: firebaseCredential)
                    uid = linked.user.uid
                } else {
                    let signedIn = try await Auth.auth().signIn(with: firebaseCredential)
                    uid = signedIn.user.uid
                }
                isSignedIn = true
                isAnonymous = Auth.auth().currentUser?.isAnonymous ?? false
                lastError = nil
                await restore(context: context)
                // Now that we're linked to a durable account, seed anything the
                // account is genuinely missing (gated on a confirmed-empty
                // cloud) and push local edits made before the link.
                await seed(context: context)
                await backup(context: context)
            } catch let error as NSError where error.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                // This Apple ID already has an account — sign into it.
                if let updated = error.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential,
                   let signedIn = try? await Auth.auth().signIn(with: updated) {
                    uid = signedIn.user.uid
                    isSignedIn = true
                    isAnonymous = false
                    await restore(context: context)
                } else {
                    lastError = "This Apple ID is already linked to another account."
                }
            } catch {
                lastError = "Apple sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = "", remaining = length
        while remaining > 0 {
            var byte: UInt8 = 0
            if SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess {
                result.append(charset[Int(byte) % charset.count]); remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func userDoc() -> DocumentReference? {
        guard let uid else { return nil }
        return db.collection("users").document(uid)
    }

    /// Signs out of the current account and returns to a fresh anonymous user.
    /// Local data stays on the device; sign in with Apple again to re-link.
    func signOut() async {
        try? Auth.auth().signOut()
        uid = nil
        isSignedIn = false
        isAnonymous = true
        await signIn()
    }

    // MARK: - Auto-backup (debounced)

    /// Schedules a backup shortly after the last edit, coalescing rapid edits
    /// into a single upload so the cloud stays current without manual taps.
    func requestBackup(context: ModelContext, debounce: TimeInterval = 20) {
        pendingBackup?.cancel()
        pendingBackup = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.backup(context: context)
        }
    }

    /// Hard-deletes specific documents from a user collection (merge-writes
    /// never delete, so removals must be pushed explicitly or they return on
    /// restore). Used for retro, whose ids are stable and structural.
    func delete(collection name: String, ids: [String]) async {
        guard !ids.isEmpty else { return }
        if uid == nil { await signIn() }
        guard let root = userDoc() else { return }
        for chunk in ids.chunked(into: 400) {
            let batch = db.batch()
            for id in chunk { batch.deleteDocument(root.collection(name).document(id)) }
            try? await batch.commit()
        }
    }

    /// Soft-deletes (tombstones) documents so the deletion survives a merge and
    /// is filtered out on every device's restore — a hard delete would let the
    /// record resurrect if another device re-pushed it before syncing.
    func softDelete(collection name: String, ids: [String]) async {
        guard !ids.isEmpty else { return }
        if uid == nil { await signIn() }
        guard let root = userDoc() else { return }
        for chunk in ids.chunked(into: 400) {
            let batch = db.batch()
            for id in chunk {
                batch.setData(["deleted": true, "updatedAt": Date()],
                              forDocument: root.collection(name).document(id), merge: true)
            }
            try? await batch.commit()
        }
    }

    // MARK: - Per-account seed/migration flags (users/{uid}/meta/flags)

    /// A migration/seed already applied to this ACCOUNT. Falls back to the
    /// legacy per-device UserDefaults flag so existing single-device installs
    /// keep their state and never re-seed after upgrading.
    func accountFlag(_ key: String) -> Bool {
        accountFlags[key] ?? UserDefaults.standard.bool(forKey: key)
    }

    private func setAccountFlag(_ key: String) async {
        accountFlags[key] = true
        UserDefaults.standard.set(true, forKey: key)   // mirror for offline reads
        guard let root = userDoc() else { return }
        try? await root.collection("meta").document("flags").setData([key: true], merge: true)
    }

    // MARK: - Gated seeding

    /// Seeds bundled history ONLY into collections the account is genuinely
    /// missing: the restore must have reached Firestore, the cloud collection
    /// must have been confirmed empty, and the per-account flag must be unset.
    /// This makes a 2nd-device install safe — it never overwrites cloud data.
    func seed(context: ModelContext) async {
        let seedRetro = restoreSucceeded && cloudRetroWasEmpty && !accountFlag("retroReimportV5")
        let seedBiomarkers = restoreSucceeded && cloudDailyMetricsWasEmpty && !accountFlag("biomarkerSeedV2")
        let seedWorkouts = restoreSucceeded && cloudWorkoutsWasEmpty && !accountFlag("workoutSeedV1")

        let result = Bootstrap.run(context: context,
                                   seedRetro: seedRetro,
                                   seedBiomarkers: seedBiomarkers,
                                   seedWorkouts: seedWorkouts)
        if result.seededRetro { await setAccountFlag("retroReimportV5") }
        if result.seededBiomarkers { await setAccountFlag("biomarkerSeedV2") }
        if result.seededWorkouts { await setAccountFlag("workoutSeedV1") }
        bootstrapDone = true
    }

    // MARK: - Backup (local → cloud)

    /// - Parameter isLaunch: the automatic launch backup. Suppressed for a
    ///   brand-new anonymous session (no prior backup) so a 2nd device can't
    ///   orphan/push its freshly-seeded data before the user links an account.
    ///   Anonymous uids aren't recoverable after a wipe anyway, so nothing is
    ///   lost by waiting for the link.
    /// - Parameter full: push every record regardless of timestamp (the
    ///   manual "Back up now"). Otherwise only records stamped after the last
    ///   backup go up — the whole dataset used to be re-sent (thousands of
    ///   daily metrics, every activity's raw JSON) twenty seconds after any
    ///   keystroke, and Firestore writes each of those into its local cache
    ///   too, which is where much of the app's stutter came from.
    func backup(context: ModelContext, isLaunch: Bool = false, full: Bool = false) async {
        guard !isSyncing else { return }
        if isLaunch && isAnonymous && lastBackup == nil { return }
        if uid == nil { await signIn() }
        guard let root = userDoc() else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // Make sure the background context sees everything the UI wrote.
        try? context.save()
        let container = context.container
        let startedAt = Date()
        // Five minutes of slack: a record stamped just before the previous
        // backup started but saved after it read is still caught.
        let since: Date? = full ? nil : lastBackup?.addingTimeInterval(-300)

        do {
            try await push(root.collection("dailyMetrics"), await Self.changed(
                DailyMetric.self, in: container, since: since, stamp: \.fetchedAt,
                id: { $0.id }, data: {
                    ["day": $0.day, "metricKey": $0.metricKey, "value": $0.value, "fetchedAt": $0.fetchedAt]
                }))
            try await push(root.collection("activities"), await Self.changed(
                CachedActivity.self, in: container, since: since, stamp: \.fetchedAt,
                id: { String($0.activityId) }, data: {
                    ["activityId": $0.activityId, "name": $0.name, "typeKey": $0.typeKey,
                     "startDate": $0.startDate, "durationSec": $0.durationSec, "calories": $0.calories,
                     "trainingLoad": $0.trainingLoad, "zoneSeconds": $0.zoneSeconds,
                     "rawSummaryJSON": $0.rawSummaryJSON, "rawZonesJSON": $0.rawZonesJSON,
                     "fetchedAt": $0.fetchedAt]
                }))
            try await push(root.collection("retroRows"), await Self.changed(
                RetroRow.self, in: container, since: since, stamp: \.updatedAt,
                id: { $0.id }, data: { ["name": $0.name, "order": $0.order, "excluded": $0.excluded, "updatedAt": $0.updatedAt] }))
            try await push(root.collection("retroColumns"), await Self.changed(
                RetroColumn.self, in: container, since: since, stamp: \.updatedAt,
                id: { $0.id }, data: { ["label": $0.label, "order": $0.order, "updatedAt": $0.updatedAt] }))
            try await push(root.collection("retroCells"), await Self.changed(
                RetroCell.self, in: container, since: since, stamp: \.updatedAt,
                id: { $0.id }, data: { ["rowId": $0.rowId, "colId": $0.colId, "text": $0.text, "updatedAt": $0.updatedAt] }))
            try await push(root.collection("dreams"), await Self.changed(
                RetroDream.self, in: container, since: since, stamp: \.updatedAt,
                id: { $0.id }, data: { ["title": $0.title, "status": $0.status, "rationale": $0.rationale, "order": $0.order, "updatedAt": $0.updatedAt] }))
            try await push(root.collection("longevityRules"), await Self.changed(
                LongevityRule.self, in: container, since: since, stamp: \.updatedAt,
                id: { $0.id }, data: { ["text": $0.text, "order": $0.order, "updatedAt": $0.updatedAt] }))
            try await push(root.collection("workoutBlocks"), await Self.changed(
                WorkoutBlock.self, in: container, since: since, stamp: \.updatedAt,
                id: { $0.id }, data: { ["title": $0.title, "content": $0.content, "order": $0.order, "updatedAt": $0.updatedAt] }))

            let ud = UserDefaults.standard
            try await root.collection("meta").document("profile").setData([
                "dob": ud.double(forKey: "profile.dob"),
                "heightCm": ud.integer(forKey: "profile.heightCm"),
                "baselineKcal": ud.integer(forKey: "profile.baselineKcal"),
            ], merge: true)
            // Custom biomarker definitions (values sync via dailyMetrics).
            let customJSON = (ud.data(forKey: "customMetrics")).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try await root.collection("meta").document("customMetrics").setData(["json": customJSON], merge: true)

            lastBackup = startedAt
            UserDefaults.standard.set(startedAt.timeIntervalSince1970, forKey: "cloud.lastBackup")
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// The records of one model type stamped after `since` (all of them when
    /// nil), read on a background context and flattened to plain dictionaries,
    /// so the main actor never walks thousands of SwiftData objects.
    nonisolated private static func changed<T: PersistentModel>(
        _ type: T.Type, in container: ModelContainer, since: Date?,
        stamp: KeyPath<T, Date>,
        id: @escaping (T) -> String, data: @escaping (T) -> [String: Any]
    ) async -> [(id: String, data: [String: Any])] {
        await Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            let all = (try? ctx.fetch(FetchDescriptor<T>())) ?? []
            return all.compactMap { rec -> (id: String, data: [String: Any])? in
                if let since, rec[keyPath: stamp] <= since { return nil }
                return (id(rec), data(rec))
            }
        }.value
    }

    /// Writes records in batches of 400 (Firestore's limit is 500 per commit).
    private func push(_ collection: CollectionReference,
                      _ records: [(id: String, data: [String: Any])]) async throws {
        guard !records.isEmpty else { return }
        for chunk in records.chunked(into: 400) {
            let batch = db.batch()
            for r in chunk { batch.setData(r.data, forDocument: collection.document(r.id), merge: true) }
            try await batch.commit()
        }
    }

    /// One collection's documents, or only those stamped after `since`.
    private func docs(_ collection: CollectionReference, stamp: String, since: Date?) async throws -> [QueryDocumentSnapshot] {
        if let since {
            return try await collection.whereField(stamp, isGreaterThan: Timestamp(date: since)).getDocuments().documents
        }
        return try await collection.getDocuments().documents
    }

    // MARK: - Restore (cloud → local)

    /// - Parameter incremental: only pull documents stamped after the last
    ///   restore (the foreground refresh). Launch, sign-in and the manual
    ///   "Restore" stay full so the seeding decisions below see the whole
    ///   cloud collection.
    func restore(context: ModelContext, incremental: Bool = false) async {
        defer { didRestore = true }
        restoreSucceeded = false
        if uid == nil { await signIn() }
        guard let root = userDoc() else { return }
        let startedAt = Date()
        let since: Date? = incremental ? lastRestore?.addingTimeInterval(-300) : nil
        do {
            // Per-account seed/migration flags — load before any seeding decision.
            if let flags = try? await root.collection("meta").document("flags").getDocument(),
               let d = flags.data() {
                for (k, v) in d { if let b = v as? Bool { accountFlags[k] = b } }
            }
            // DailyMetric — last-writer-wins on fetchedAt (never clobber a newer
            // local edit with older cloud data).
            let metricDocs = try await docs(root.collection("dailyMetrics"), stamp: "fetchedAt", since: since)
            if since == nil { cloudDailyMetricsWasEmpty = metricDocs.isEmpty }
            let existingMetrics: [String: DailyMetric]
            if since == nil {
                existingMetrics = Dictionary((try? context.fetch(FetchDescriptor<DailyMetric>()))?.map { ($0.id, $0) } ?? [],
                                             uniquingKeysWith: { a, _ in a })
            } else {
                // Incremental: look up only the handful of ids that changed.
                let ids = metricDocs.map(\.documentID)
                let predicate = #Predicate<DailyMetric> { ids.contains($0.id) }
                existingMetrics = Dictionary((try? context.fetch(FetchDescriptor(predicate: predicate)))?.map { ($0.id, $0) } ?? [],
                                             uniquingKeysWith: { a, _ in a })
            }
            for doc in metricDocs {
                let d = doc.data()
                guard let key = d["metricKey"] as? String,
                      let value = d["value"] as? Double,
                      let day = (d["day"] as? Timestamp)?.dateValue() else { continue }
                let cloudAt = (d["fetchedAt"] as? Timestamp)?.dateValue()
                if let m = existingMetrics[doc.documentID] {
                    if let cloudAt, cloudAt > m.fetchedAt { m.value = value; m.fetchedAt = cloudAt }
                } else {
                    let nm = DailyMetric(day: day, metricKey: key, value: value)
                    if let cloudAt { nm.fetchedAt = cloudAt }
                    context.insert(nm)
                }
            }
            // Retro rows/columns/cells, dreams, longevity, workouts.
            try await restoreRetro(root: root, context: context, since: since)
            // Profile (editable reference values)
            if let doc = try? await root.collection("meta").document("profile").getDocument(), let d = doc.data() {
                let ud = UserDefaults.standard
                if let dob = d["dob"] as? Double, dob > 0 { ud.set(dob, forKey: "profile.dob") }
                if let h = d["heightCm"] as? Int, h > 0 { ud.set(h, forKey: "profile.heightCm") }
                if let k = d["baselineKcal"] as? Int, k > 0 { ud.set(k, forKey: "profile.baselineKcal") }
            }
            if let doc = try? await root.collection("meta").document("customMetrics").getDocument(),
               let json = doc.data()?["json"] as? String, let data = json.data(using: .utf8) {
                UserDefaults.standard.set(data, forKey: "customMetrics")
            }
            try? context.save()
            restoreSucceeded = true
            lastRestore = startedAt
            UserDefaults.standard.set(startedAt.timeIntervalSince1970, forKey: "cloud.lastRestore")
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Returns true if the cloud doc is a tombstone; if a local record matches,
    /// deletes it so the deletion propagates instead of resurrecting.
    private func handleTombstone(_ d: [String: Any], id: String,
                                 local: [String: some PersistentModel],
                                 context: ModelContext) -> Bool {
        guard d["deleted"] as? Bool == true else { return false }
        if let obj = local[id] { context.delete(obj) }
        return true
    }

    /// True when the cloud copy should overwrite the matching local record:
    /// only when cloud's updatedAt is newer (missing cloud stamp ⇒ keep local).
    private func cloudWins(_ d: [String: Any], localUpdatedAt: Date) -> Bool {
        guard let cloudAt = (d["updatedAt"] as? Timestamp)?.dateValue() else { return false }
        return cloudAt >= localUpdatedAt
    }

    private func restoreRetro(root: DocumentReference, context: ModelContext, since: Date?) async throws {
        let rows = Dictionary((try? context.fetch(FetchDescriptor<RetroRow>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let rowDocs = try await docs(root.collection("retroRows"), stamp: "updatedAt", since: since)
        for doc in rowDocs {
            let d = doc.data()
            if handleTombstone(d, id: doc.documentID, local: rows, context: context) { continue }
            guard let name = d["name"] as? String, let order = d["order"] as? Int else { continue }
            let excluded = d["excluded"] as? Bool ?? false
            if let r = rows[doc.documentID] {
                if cloudWins(d, localUpdatedAt: r.updatedAt) { r.name = name; r.order = order; r.excluded = excluded; r.updatedAt = (d["updatedAt"] as? Timestamp)?.dateValue() ?? r.updatedAt }
            }
            else { context.insert(RetroRow(id: doc.documentID, name: name, order: order, excluded: excluded)) }
        }
        let cols = Dictionary((try? context.fetch(FetchDescriptor<RetroColumn>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let colDocs = try await docs(root.collection("retroColumns"), stamp: "updatedAt", since: since)
        for doc in colDocs {
            let d = doc.data()
            if handleTombstone(d, id: doc.documentID, local: cols, context: context) { continue }
            guard let label = d["label"] as? String, let order = d["order"] as? Int else { continue }
            if let c = cols[doc.documentID] {
                if cloudWins(d, localUpdatedAt: c.updatedAt) { c.label = label; c.order = order; c.updatedAt = (d["updatedAt"] as? Timestamp)?.dateValue() ?? c.updatedAt }
            }
            else { context.insert(RetroColumn(id: doc.documentID, label: label, order: order)) }
        }
        let cells = Dictionary((try? context.fetch(FetchDescriptor<RetroCell>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let cellDocs = try await docs(root.collection("retroCells"), stamp: "updatedAt", since: since)
        if since == nil { cloudRetroWasEmpty = rowDocs.isEmpty && colDocs.isEmpty && cellDocs.isEmpty }
        for doc in cellDocs {
            let d = doc.data()
            if handleTombstone(d, id: doc.documentID, local: cells, context: context) { continue }
            guard let rowId = d["rowId"] as? String, let colId = d["colId"] as? String, let text = d["text"] as? String else { continue }
            if let c = cells[doc.documentID] {
                if cloudWins(d, localUpdatedAt: c.updatedAt) { c.text = text; c.updatedAt = (d["updatedAt"] as? Timestamp)?.dateValue() ?? c.updatedAt }
            }
            else { context.insert(RetroCell(rowId: rowId, colId: colId, text: text)) }
        }
        let dreams = Dictionary((try? context.fetch(FetchDescriptor<RetroDream>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await docs(root.collection("dreams"), stamp: "updatedAt", since: since) {
            let d = doc.data()
            if handleTombstone(d, id: doc.documentID, local: dreams, context: context) { continue }
            guard let title = d["title"] as? String else { continue }
            if let x = dreams[doc.documentID] {
                if cloudWins(d, localUpdatedAt: x.updatedAt) { x.title = title; x.status = d["status"] as? String ?? x.status; x.rationale = d["rationale"] as? String ?? x.rationale; x.updatedAt = (d["updatedAt"] as? Timestamp)?.dateValue() ?? x.updatedAt }
            }
            else { context.insert(RetroDream(id: doc.documentID, title: title, status: d["status"] as? String ?? "", rationale: d["rationale"] as? String ?? "", order: d["order"] as? Int ?? 0)) }
        }
        let rules = Dictionary((try? context.fetch(FetchDescriptor<LongevityRule>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await docs(root.collection("longevityRules"), stamp: "updatedAt", since: since) {
            let d = doc.data()
            if handleTombstone(d, id: doc.documentID, local: rules, context: context) { continue }
            guard let text = d["text"] as? String else { continue }
            if let x = rules[doc.documentID] {
                if cloudWins(d, localUpdatedAt: x.updatedAt) { x.text = text; x.updatedAt = (d["updatedAt"] as? Timestamp)?.dateValue() ?? x.updatedAt }
            }
            else { context.insert(LongevityRule(id: doc.documentID, text: text, order: d["order"] as? Int ?? 0)) }
        }
        let workouts = Dictionary((try? context.fetch(FetchDescriptor<WorkoutBlock>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let workoutDocs = try await docs(root.collection("workoutBlocks"), stamp: "updatedAt", since: since)
        if since == nil { cloudWorkoutsWasEmpty = workoutDocs.isEmpty }
        for doc in workoutDocs {
            let d = doc.data()
            if handleTombstone(d, id: doc.documentID, local: workouts, context: context) { continue }
            guard let title = d["title"] as? String else { continue }
            if let x = workouts[doc.documentID] {
                if cloudWins(d, localUpdatedAt: x.updatedAt) { x.title = title; x.content = d["content"] as? String ?? x.content; x.updatedAt = (d["updatedAt"] as? Timestamp)?.dateValue() ?? x.updatedAt }
            }
            else { context.insert(WorkoutBlock(id: doc.documentID, title: title, content: d["content"] as? String ?? "", order: d["order"] as? Int ?? 0)) }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
