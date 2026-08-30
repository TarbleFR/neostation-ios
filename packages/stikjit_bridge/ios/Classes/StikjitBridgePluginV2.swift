import Flutter
import Foundation
import UIKit

/// Experimental post-JIT handoff for MeloNX.
///
/// The legacy bridge launches MeloNX suspended, enables JIT with universal.js
/// and detaches. Do not explicitly resume MeloNX through process_control before
/// opening the frontend URL: that foregrounds MeloNX first and can leave
/// NeoStation backgrounded, causing UIApplication.open to reject the request.
/// Instead, deliver the registered MeloNX URL while NeoStation still owns the
/// foreground. iOS then activates the already-JITed suspended MeloNX process and
/// delivers the URL in one handoff.
public final class StikjitBridgePluginV2: NSObject, FlutterPlugin {
  private let legacy = StikjitBridgePlugin()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "neostation/stikjit",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(StikjitBridgePluginV2(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enableMeloNxJit" else {
      legacy.handle(call, result: result)
      return
    }

    guard
      let arguments = call.arguments as? [String: Any],
      let gameUrlString = arguments["gameUrl"] as? String,
      let gameUrl = URL(string: gameUrlString),
      !gameUrlString.isEmpty
    else {
      result(
        FlutterError(
          code: "stikjit_invalid_game_url",
          message: "A valid MeloNX game URL is required for the post-JIT handoff.",
          details: nil
        )
      )
      return
    }

    legacy.handle(call) { value in
      guard var response = value as? [String: Any] else {
        result(value)
        return
      }

      var logs = response["logs"] as? [String] ?? []
      logs.append(
        "Post-JIT handoff: opening MeloNX frontend URL before any explicit process-control resume."
      )
      logs.append("Post-JIT URL: \(gameUrl.absoluteString)")
      response["logs"] = logs

      DispatchQueue.main.async {
        UIApplication.shared.open(gameUrl, options: [:]) { opened in
          var completed = response
          var completedLogs = completed["logs"] as? [String] ?? []
          completed["gameUrlOpened"] = opened
          if opened {
            completedLogs.append(
              "UIApplication.open accepted the MeloNX URL; iOS should resume the existing JITed process and deliver the game request."
            )
          } else {
            completedLogs.append(
              "UIApplication.open rejected the MeloNX URL before explicit resume."
            )
          }
          completed["logs"] = completedLogs
          result(completed)
        }
      }
    }
  }
}
