import Foundation

@main struct QuickToolsTests {
    @MainActor static func main() async {
        let store = QuickToolsStore()

        func check(_ category: ConversionCategory, from: String, to: String,
                   amount: String, expected: Double, tolerance: Double = 0.00001) {
            store.selectCategory(category)
            let units = category.units
            store.selectSource(units.firstIndex { $0.symbol == from }!)
            store.selectTarget(units.firstIndex { $0.symbol == to }!)
            store.amount = amount
            guard let actual = store.convertedAmount else {
                preconditionFailure("Missing \(category) conversion")
            }
            precondition(abs(actual - expected) < tolerance,
                         "\(category): \(actual) != \(expected)")
        }

        check(.length, from: "mi", to: "km", amount: "1", expected: 1.609344)
        check(.weight, from: "lb", to: "kg", amount: "1", expected: 0.45359237)
        check(.temperature, from: "°F", to: "°C", amount: "32", expected: 0)
        check(.temperature, from: "K", to: "°F", amount: "273.15", expected: 32)
        check(.volume, from: "gal", to: "L", amount: "1", expected: 3.785411784)
        check(.area, from: "ac", to: "m²", amount: "1", expected: 4_046.8564224)
        check(.speed, from: "mph", to: "m/s", amount: "1", expected: 0.44704)

        store.selectCategory(.currency)
        precondition(store.convertedAmount == nil, "A currency rate must be fetched")
        store.selectTarget(0)
        precondition(store.convertedAmount == 1, "Same currency should convert at 1:1")
        store.shutdown()

        #if QUICKTOOLS_PROCESS_FIXTURE
        // These jobs run /bin/sleep only; no user Shortcut is launched.
        await QuickToolsProcessFixture.verifyTimeoutAndCancellation()
        #endif
        print("Quick tools tests passed")
    }
}
