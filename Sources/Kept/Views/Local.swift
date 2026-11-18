import SwiftUI

/// View-local state. Stands in for `@State`, which in the current SDK is a macro whose compiler plugin
/// ships only with Xcode; this wrapper keeps Kept buildable with the Command Line Tools alone.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var state: State<Value>

    init(wrappedValue: Value) {
        state = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
