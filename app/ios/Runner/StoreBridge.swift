import Flutter
import StoreKit
import UIKit

/// StoreKit 2 內購橋接(Dart 端是 lib/src/purchases.dart 的 StoreKitPurchaseService):
///   * 14 天試用 = US$0 的非消耗型品項(審查準則 3.1.1)。試用起點取那筆交易的
///     購買日,跟著 Apple 帳號走,重裝、換手機都不會重新計時
///   * 解鎖 = 一次性非消耗型品項
/// 權限只看 Transaction.currentEntitlements 裡驗證過、沒被撤銷的交易;
/// Transaction.updates(別台裝置買的、Ask to Buy 核准、退款撤銷)一來就通知 Dart 重讀。
///
/// channel `tterm/store`:
///   Dart → native:entitlements、products、purchase(productID)、restore
///   native → Dart:changed(權限可能變了,請重讀)
@MainActor
final class StoreBridge: NSObject {
  static let shared = StoreBridge()

  static let trialID = "dev.tterm.ttermApp.trial14"
  static let unlockID = "dev.tterm.ttermApp.unlock"

  private var channel: FlutterMethodChannel?
  private weak var scene: UIScene?
  private var updates: Task<Void, Never>?
  private var products: [String: Product] = [:]

  func attach(messenger: FlutterBinaryMessenger, scene: UIScene) {
    self.scene = scene
    let channel = FlutterMethodChannel(name: "tterm/store", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      Task { @MainActor in await self.handle(call, result) }
    }
    self.channel = channel
    listenForTransactions()
    // Dart 可能在 channel 接上前就問過了
    notifyChanged()
  }

  // MARK: - 交易

  /// Apple 建議 app 一啟動就開始聽,不然 app 外完成的交易會漏接。
  private func listenForTransactions() {
    guard updates == nil else { return }
    updates = Task.detached { [weak self] in
      for await update in Transaction.updates {
        if case .verified(let transaction) = update {
          await transaction.finish()
        }
        await self?.notifyChanged()
      }
    }
    // 上次沒來得及 finish 的(例如購買途中 app 被關掉)
    Task.detached {
      for await pending in Transaction.unfinished {
        if case .verified(let transaction) = pending {
          await transaction.finish()
        }
      }
    }
  }

  private func notifyChanged() {
    channel?.invokeMethod("changed", arguments: nil)
  }

  // MARK: - Dart 呼叫

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) async {
    switch call.method {
    case "entitlements":
      result(await entitlements())
    case "products":
      do {
        result(try await loadProducts())
      } catch {
        result(FlutterError(code: "products", message: error.localizedDescription, details: nil))
      }
    case "purchase":
      guard let id = call.arguments as? String else {
        return result(FlutterError(code: "args", message: "product ID missing", details: nil))
      }
      do {
        result(try await purchase(id))
      } catch let error as StoreBridgeError {
        result(FlutterError(code: error.rawValue, message: nil, details: nil))
      } catch {
        result(FlutterError(code: "purchase", message: error.localizedDescription, details: nil))
      }
    case "restore":
      do {
        // 會跳 Apple 帳號登入;Apple 只建議在使用者按「恢復購買」時呼叫
        try await AppStore.sync()
        result(nil)
      } catch StoreKitError.userCancelled {
        result(FlutterError(code: "cancelled", message: nil, details: nil))
      } catch {
        result(FlutterError(code: "restore", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// `{unlocked: Bool, trialStart: 毫秒 epoch(沒試用過就沒有這個 key)}`
  private func entitlements() async -> [String: Any] {
    var unlocked = false
    var trialStart: Date?
    for await entitlement in Transaction.currentEntitlements {
      // 沒通過驗證的交易不算;有 revocationDate = 退款或被撤銷,收回權限
      guard case .verified(let transaction) = entitlement,
        transaction.revocationDate == nil
      else { continue }
      switch transaction.productID {
      case Self.unlockID:
        unlocked = true
      case Self.trialID:
        // 非消耗型的 purchaseDate 就是當初買的時間;保險起見跟原始購買日取較早的
        let start = min(transaction.purchaseDate, transaction.originalPurchaseDate)
        trialStart = min(trialStart ?? start, start)
      default:
        break
      }
    }
    var out: [String: Any] = ["unlocked": unlocked]
    if let trialStart {
      out["trialStart"] = trialStart.timeIntervalSince1970 * 1000
    }
    return out
  }

  /// `{productID: {price: 在地價格字串, name: 顯示名稱}}`,商店裡找不到的品項不會出現。
  private func loadProducts() async throws -> [String: Any] {
    let list = try await Product.products(for: [Self.trialID, Self.unlockID])
    var out: [String: Any] = [:]
    for product in list {
      products[product.id] = product
      out[product.id] = ["price": product.displayPrice, "name": product.displayName]
    }
    return out
  }

  /// 回傳 success / cancelled / pending。
  private func purchase(_ id: String) async throws -> String {
    var product = products[id]
    if product == nil {
      product = try await Product.products(for: [id]).first
      products[id] = product
    }
    guard let product else { throw StoreBridgeError.productNotFound }

    let outcome: Product.PurchaseResult
    if #available(iOS 17.0, *), let scene {
      outcome = try await product.purchase(confirmIn: scene)
    } else {
      outcome = try await product.purchase()
    }
    switch outcome {
    case .success(let verification):
      guard case .verified(let transaction) = verification else {
        throw StoreBridgeError.unverified
      }
      await transaction.finish()
      return "success"
    case .pending:
      return "pending"
    case .userCancelled:
      return "cancelled"
    @unknown default:
      return "cancelled"
    }
  }
}

/// 錯誤代碼直接當 FlutterError.code,文案在 Dart 端翻(lib/l10n/*.arb)。
enum StoreBridgeError: String, Error {
  case productNotFound = "not_found"
  case unverified = "unverified"
}
