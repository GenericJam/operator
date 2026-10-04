// Registers Operator's own native views with MobNativeViewRegistry, as
// MainActivity does on Android. A plain C symbol (@_cdecl) so AppDelegate.m
// can call it next to mob_register_plugins(), before the first screen mounts.
@_cdecl("operator_register_views")
public func operatorRegisterViews() {
    OperatorApproval.register()
    OperatorMarkdown.register()
}
