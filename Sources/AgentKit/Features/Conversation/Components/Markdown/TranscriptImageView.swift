//
//  TranscriptImageView.swift
//  AgentKit
//
//  Renders an image from a markdown image node (![alt](url)).
//  Handles loading, success, and failure states.
//

import SwiftUI

/// Renders a markdown image with async loading, fallback, and size constraints.
struct TranscriptImageView: View {
    let urlString: String?
    let altText: String

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(320, imageWidth))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    imageFallback
                case .empty:
                    ProgressView()
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                @unknown default:
                    imageFallback
                }
            }
        } else {
            imageFallback
        }
    }

    private var imageFallback: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.caption)
            Text(altText.isEmpty ? "Image" : altText)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private var imageWidth: CGFloat {
        #if os(iOS)
        UIScreen.main.bounds.width - 40
        #else
        400
        #endif
    }
}
