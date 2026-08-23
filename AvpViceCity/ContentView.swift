//
//  ContentView.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import SwiftUI

struct ContentView: View {

    var body: some View {
        VStack {
            Text("AvpViceCity")

            ToggleImmersiveSpaceButton()
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
