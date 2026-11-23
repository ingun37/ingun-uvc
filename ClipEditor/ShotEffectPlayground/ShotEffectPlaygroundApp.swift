//
//  ShotEffectPlaygroundApp.swift
//  ShotEffectPlayground
//
//  Created by Ingun Jon on 11/23/26.
//

import SwiftUI

@main
struct ShotEffectPlaygroundApp: App {
    @State private var shotEffects = ShotEffectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(shotEffects)
        }
        WindowGroup("Shot effect", for: ShotEffectWindow.self) { $selection in
            if let selection {
                ShotEffectView(selection: selection)
                    .environment(shotEffects)
            }
        }
    }
}
