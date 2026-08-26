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

    private var uid: String?
    private var currentNonce: String?
    private var pendingBackup: Task<Void, Never>?
    private var db: Firestore { Firestore.firestore() }

    init() {
        if let ts = UserDefaults.standard.object(forKey: "cloud.lastBackup") as? Double {
            lastBackup = Date(timeIntervalSince1970: ts)
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

    // MARK: - Backup (local → cloud)

    func backup(context: ModelContext) async {
        guard !isSyncing else { return }
        if uid == nil { await signIn() }
        guard let root = userDoc() else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await push(root.collection("dailyMetrics"),
                           (try? context.fetch(FetchDescriptor<DailyMetric>())) ?? [],
                           id: { $0.id }, data: {
                ["day": $0.day, "metricKey": $0.metricKey, "value": $0.value, "fetchedAt": $0.fetchedAt]
            })
            try await push(root.collection("activities"),
                           (try? context.fetch(FetchDescriptor<CachedActivity>())) ?? [],
                           id: { String($0.activityId) }, data: {
                ["activityId": $0.activityId, "name": $0.name, "typeKey": $0.typeKey,
                 "startDate": $0.startDate, "durationSec": $0.durationSec, "calories": $0.calories,
                 "trainingLoad": $0.trainingLoad, "zoneSeconds": $0.zoneSeconds,
                 "rawSummaryJSON": $0.rawSummaryJSON, "rawZonesJSON": $0.rawZonesJSON]
            })
            try await push(root.collection("retroRows"),
                           (try? context.fetch(FetchDescriptor<RetroRow>())) ?? [],
                           id: { $0.id }, data: { ["name": $0.name, "order": $0.order] })
            try await push(root.collection("retroColumns"),
                           (try? context.fetch(FetchDescriptor<RetroColumn>())) ?? [],
                           id: { $0.id }, data: { ["label": $0.label, "order": $0.order] })
            try await push(root.collection("retroCells"),
                           (try? context.fetch(FetchDescriptor<RetroCell>())) ?? [],
                           id: { $0.id }, data: { ["rowId": $0.rowId, "colId": $0.colId, "text": $0.text] })
            try await push(root.collection("dreams"),
                           (try? context.fetch(FetchDescriptor<RetroDream>())) ?? [],
                           id: { $0.id }, data: { ["title": $0.title, "status": $0.status, "rationale": $0.rationale, "order": $0.order] })
            try await push(root.collection("longevityRules"),
                           (try? context.fetch(FetchDescriptor<LongevityRule>())) ?? [],
                           id: { $0.id }, data: { ["text": $0.text, "order": $0.order] })
            try await push(root.collection("workoutBlocks"),
                           (try? context.fetch(FetchDescriptor<WorkoutBlock>())) ?? [],
                           id: { $0.id }, data: { ["title": $0.title, "content": $0.content, "order": $0.order] })

            let ud = UserDefaults.standard
            try await root.collection("meta").document("profile").setData([
                "dob": ud.double(forKey: "profile.dob"),
                "heightCm": ud.integer(forKey: "profile.heightCm"),
                "baselineKcal": ud.integer(forKey: "profile.baselineKcal"),
            ], merge: true)
            // Custom biomarker definitions (values sync via dailyMetrics).
            let customJSON = (ud.data(forKey: "customMetrics")).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try await root.collection("meta").document("customMetrics").setData(["json": customJSON], merge: true)

            lastBackup = Date()
            UserDefaults.standard.set(lastBackup!.timeIntervalSince1970, forKey: "cloud.lastBackup")
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Writes items in batches of 400 (Firestore's limit is 500 per commit).
    private func push<T>(_ collection: CollectionReference, _ items: [T],
                         id: (T) -> String, data: (T) -> [String: Any]) async throws {
        for chunk in items.chunked(into: 400) {
            let batch = db.batch()
            for item in chunk { batch.setData(data(item), forDocument: collection.document(id(item)), merge: true) }
            try await batch.commit()
        }
    }

    // MARK: - Restore (cloud → local)

    func restore(context: ModelContext) async {
        defer { didRestore = true }
        if uid == nil { await signIn() }
        guard let root = userDoc() else { return }
        do {
            // DailyMetric
            let existingMetrics = Dictionary((try? context.fetch(FetchDescriptor<DailyMetric>()))?.map { ($0.id, $0) } ?? [],
                                             uniquingKeysWith: { a, _ in a })
            for doc in try await root.collection("dailyMetrics").getDocuments().documents {
                let d = doc.data()
                guard let key = d["metricKey"] as? String,
                      let value = d["value"] as? Double,
                      let day = (d["day"] as? Timestamp)?.dateValue() else { continue }
                if let m = existingMetrics[doc.documentID] { m.value = value }
                else { context.insert(DailyMetric(day: day, metricKey: key, value: value)) }
            }
            // Retro rows/columns/cells, dreams, longevity (structure the user edits)
            try await restoreRetro(root: root, context: context)
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
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func restoreRetro(root: DocumentReference, context: ModelContext) async throws {
        let rows = Dictionary((try? context.fetch(FetchDescriptor<RetroRow>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await root.collection("retroRows").getDocuments().documents {
            let d = doc.data()
            guard let name = d["name"] as? String, let order = d["order"] as? Int else { continue }
            if let r = rows[doc.documentID] { r.name = name; r.order = order }
            else { context.insert(RetroRow(id: doc.documentID, name: name, order: order)) }
        }
        let cols = Dictionary((try? context.fetch(FetchDescriptor<RetroColumn>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await root.collection("retroColumns").getDocuments().documents {
            let d = doc.data()
            guard let label = d["label"] as? String, let order = d["order"] as? Int else { continue }
            if let c = cols[doc.documentID] { c.label = label; c.order = order }
            else { context.insert(RetroColumn(id: doc.documentID, label: label, order: order)) }
        }
        let cells = Dictionary((try? context.fetch(FetchDescriptor<RetroCell>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await root.collection("retroCells").getDocuments().documents {
            let d = doc.data()
            guard let rowId = d["rowId"] as? String, let colId = d["colId"] as? String, let text = d["text"] as? String else { continue }
            if let c = cells[doc.documentID] { c.text = text }
            else { context.insert(RetroCell(rowId: rowId, colId: colId, text: text)) }
        }
        let dreams = Dictionary((try? context.fetch(FetchDescriptor<RetroDream>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await root.collection("dreams").getDocuments().documents {
            let d = doc.data()
            guard let title = d["title"] as? String else { continue }
            if let x = dreams[doc.documentID] { x.title = title; x.status = d["status"] as? String ?? x.status; x.rationale = d["rationale"] as? String ?? x.rationale }
            else { context.insert(RetroDream(id: doc.documentID, title: title, status: d["status"] as? String ?? "", rationale: d["rationale"] as? String ?? "", order: d["order"] as? Int ?? 0)) }
        }
        let rules = Dictionary((try? context.fetch(FetchDescriptor<LongevityRule>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await root.collection("longevityRules").getDocuments().documents {
            let d = doc.data()
            guard let text = d["text"] as? String else { continue }
            if let x = rules[doc.documentID] { x.text = text }
            else { context.insert(LongevityRule(id: doc.documentID, text: text, order: d["order"] as? Int ?? 0)) }
        }
        let workouts = Dictionary((try? context.fetch(FetchDescriptor<WorkoutBlock>()))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        for doc in try await root.collection("workoutBlocks").getDocuments().documents {
            let d = doc.data()
            guard let title = d["title"] as? String else { continue }
            if let x = workouts[doc.documentID] { x.title = title; x.content = d["content"] as? String ?? x.content }
            else { context.insert(WorkoutBlock(id: doc.documentID, title: title, content: d["content"] as? String ?? "", order: d["order"] as? Int ?? 0)) }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
