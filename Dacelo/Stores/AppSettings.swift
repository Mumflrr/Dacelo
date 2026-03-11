// AppSettings.swift
// Dacelo
//
// All user-configurable settings in one isolated place.
// Injected as an @EnvironmentObject so any view can read/write
// without going through AppStore.

import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverHost") var serverHost: String = "your-pc-hostname"
    @AppStorage("serverPort") var serverPort: Int    = 8765
    @AppStorage("moveTimeMs") var moveTimeMs: Int    = 3000
}
