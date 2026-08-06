//
//  BrandMark.swift
//  notch-911
//
//  The marks of the services the app talks to, from the asset catalog.
//
//  All four are vector (`preserves-vector-representation`), because they are
//  drawn at 11pt in the notch and 16pt in the status window off the same asset.
//  OpenAI's is a template — it is monochrome by design, so it takes the colour
//  of whatever surface it lands on. The other three carry brand colour and are
//  deliberately *not* templates: a tinted Spotify green or Apple Music gradient
//  would be the wrong mark rather than a restyled one.
//

import SwiftUI

struct BrandMark: View {
    let asset: String
    var size: CGFloat

    init(_ asset: String, size: CGFloat = 14) {
        self.asset = asset
        self.size = size
    }

    var body: some View {
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // The marks are the services' own; nothing here is a control.
            .accessibilityHidden(true)
    }
}
