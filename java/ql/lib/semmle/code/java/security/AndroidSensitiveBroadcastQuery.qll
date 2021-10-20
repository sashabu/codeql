/** Provides definitions to reason about Android Sensitive Broadcast queries */

import java
import semmle.code.java.dataflow.DataFlow3
import semmle.code.java.dataflow.TaintTracking
import semmle.code.java.frameworks.android.Intent
import semmle.code.java.security.SensitiveActions

/**
 * Gets regular expression for matching names of Android variables that indicate the value being held contains sensitive information.
 */
private string getAndroidSensitiveInfoRegex() { result = "(?i).*(email|phone|ticket).*" }

/** Finds variables that hold sensitive information judging by their names. */
private class SensitiveInfoExpr extends Expr {
  SensitiveInfoExpr() {
    exists(Variable v | this = v.getAnAccess() |
      v.getName().regexpMatch([getCommonSensitiveInfoRegex(), getAndroidSensitiveInfoRegex()])
    )
  }
}

private predicate maybeNullArg(Expr ex) {
  exists(DataFlow::Node src, DataFlow::Node sink, MethodAccess ma |
    ex = ma.getAnArgument() and
    sink.asExpr() = ex and
    src.asExpr() instanceof NullLiteral
  |
    DataFlow::localFlow(src, sink)
  )
}

private predicate maybeEmptyArrayArg(Expr ex) {
  exists(DataFlow::Node src, DataFlow::Node sink, MethodAccess ma |
    ex = ma.getAnArgument() and
    sink.asExpr() = ex and
    src.asExpr().(ArrayCreationExpr).getFirstDimensionSize() = 0
  |
    DataFlow::localFlow(src, sink)
  )
}

/**
 * Holds if a `sendBroadcast` call doesn't specify receiver permission.
 */
private predicate isSensitiveBroadcastSink(DataFlow::Node sendBroadcastCallArg) {
  exists(MethodAccess ma, string name | ma.getMethod().hasName(name) |
    ma.getMethod().getDeclaringType().getASourceSupertype*() instanceof TypeContext and
    sendBroadcastCallArg.asExpr() = ma.getAnArgument() and
    (
      name = "sendBroadcast" and
      (
        // sendBroadcast(Intent intent)
        ma.getNumArgument() = 1
        or
        // sendBroadcast(Intent intent, String receiverPermission)
        maybeNullArg(ma.getArgument(1))
      )
      or
      name = "sendBroadcastAsUser" and
      (
        // sendBroadcastAsUser(Intent intent, UserHandle user)
        ma.getNumArgument() = 2
        or
        // sendBroadcastAsUser(Intent intent, UserHandle user, String receiverPermission)
        maybeNullArg(ma.getArgument(2))
      )
      or
      // sendBroadcastWithMultiplePermissions(Intent intent, String[] receiverPermissions)
      name = "sendBroadcastWithMultiplePermissions" and
      maybeEmptyArrayArg(ma.getArgument(1))
      or
      // Method calls of `sendOrderedBroadcast` whose second argument is always `receiverPermission`
      name = "sendOrderedBroadcast" and
      (
        // sendOrderedBroadcast(Intent intent, String receiverPermission)
        // sendOrderedBroadcast(Intent intent, String receiverPermission, BroadcastReceiver resultReceiver, Handler scheduler, int initialCode, String initialData, Bundle initialExtras)
        maybeNullArg(ma.getArgument(1)) and
        ma.getNumArgument() = [2, 7]
        or
        // sendOrderedBroadcast(Intent intent, String receiverPermission, String receiverAppOp, BroadcastReceiver resultReceiver, Handler scheduler, int initialCode, String initialData, Bundle initialExtras)
        maybeNullArg(ma.getArgument(1)) and
        maybeNullArg(ma.getArgument(2)) and
        ma.getNumArgument() = 8
      )
      or
      // sendOrderedBroadcastAsUser(Intent intent, UserHandle user, String receiverPermission, BroadcastReceiver resultReceiver, Handler scheduler, int initialCode, String initialData, Bundle initialExtras)
      name = "sendOrderedBroadcastAsUser" and
      maybeNullArg(ma.getArgument(2))
      or
      // sendStickyBroadcast(Intent intent)
      // sendStickyBroadcast(Intent intent, Bundle options)
      // sendStickyBroadcastAsUser(Intent intent, UserHandle user)
      // sendStickyOrderedBroadcast(Intent intent, BroadcastReceiver resultReceiver, Handler scheduler, int initialCode, String initialData, Bundle initialExtras)
      // sendStickyOrderedBroadcastAsUser(Intent intent, UserHandle user, BroadcastReceiver resultReceiver, Handler scheduler, int initialCode, String initialData, Bundle initialExtras)
      name =
        [
          "sendStickyBroadcast", "sendStickyBroadcastAsUser", "sendStickyOrderedBroadcast",
          "sendStickyOrderedBroadcastAsUser"
        ]
    )
  )
}

/**
 * Holds if `arg`  as an argument to a use of a `startActivity` or `startService` method that sends an intent to another application.
 */
private predicate isStartActivityOrServiceSink(DataFlow::Node arg) {
  exists(MethodAccess ma, string name | ma.getMethod().hasName(name) |
    arg.asExpr() = ma.getArgument(0) and
    ma.getMethod().getDeclaringType().getASourceSupertype*() instanceof TypeContext and
    // startActivity(Intent intent)
    // startActivity(Intent intent, Bundle options)
    // startActivities(Intent[] intents)
    // startActivities(Intent[] intents, Bundle options)
    // startService(Intent service)
    // startForegroundService(Intent service)
    // bindService (Intent service, int flags, Executor executor, ServiceConnection conn)
    // bindService (Intent service, Executor executor, ServiceConnection conn)
    name =
      ["startActivity", "startActivities", "startService", "startForegroundService", "bindService"]
  )
}

predicate isCleanIntent(Expr intent) {
  intent.getType() instanceof TypeIntent and
  (
    exists(MethodAccess setRecieverMa |
      setRecieverMa.getQualifier() = intent and
      setRecieverMa.getMethod().hasName(["setPackage", "setClass", "setClassName", "setComponent"])
    )
    or
    // Handle the cases where the PackageContext and Class are set at construction time
    //    Intent(Context packageContext, Class<?> cls)
    //    Intent(String action, Uri uri, Context packageContext, Class<?> cls)
    exists(ConstructorCall cc | cc = intent |
      cc.getConstructedType() instanceof TypeIntent and
      cc.getNumArgument() > 1 and
      (
        cc.getArgument(0).getType() instanceof TypeContext and
        not maybeNullArg(cc.getArgument(1))
        or
        cc.getArgument(2).getType() instanceof TypeContext and
        not maybeNullArg(cc.getArgument(3))
      )
    )
  )
}

/**
 * Taint configuration tracking flow from variables containing sensitive information to broadcast intents.
 */
class SensitiveBroadcastConfig extends TaintTracking::Configuration {
  SensitiveBroadcastConfig() { this = "Sensitive Broadcast Configuration" }

  override predicate isSource(DataFlow::Node source) {
    source.asExpr() instanceof SensitiveInfoExpr
  }

  override predicate isSink(DataFlow::Node sink) {
    isSensitiveBroadcastSink(sink)
    or
    isStartActivityOrServiceSink(sink)
  }

  /**
   * Holds if broadcast doesn't specify receiving package name of the 3rd party app
   */
  override predicate isSanitizer(DataFlow::Node node) {
    exists(DataFlow::Node intent | isCleanIntent(intent.asExpr()) |
      DataFlow::localFlow(intent, node)
    )
  }

  override predicate allowImplicitRead(DataFlow::Node node, DataFlow::Content c) {
    super.allowImplicitRead(node, c)
    or
    this.isSink(node)
  }
}
