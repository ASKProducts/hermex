import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ImageLightboxZoomTests: XCTestCase {
    private let server = URL(string: "https://example.test")!
    private let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAHklEQVR4nGNgaPhPHTRq0KhBowaNGjRq0KhBA28QAELFXe7bxBBpAAAAAElFTkSuQmCC")!

    func testTranscriptZoomSurvivesPresentingViewRedraw() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LightboxImageURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let files = WebUIWorkspaceFileClient(sessionID: UUID().uuidString, workspace: nil, server: server, apiClient: client)
        let item = TranscriptMediaPreviewItem(reference: .init(rawReference: "/image.png"))
        let model = TranscriptMediaPreviewViewModel(server: server, files: files, reference: item.reference)
        await model.load()
        try assertZoomSurvivesRedraw { revision in
            TranscriptMediaImageLightbox(server: self.server, files: files, item: item, viewModel: model,
                onAPIError: { _ in XCTFail("Unexpected media error at redraw \(revision)") })
        }
    }

    func testAttachmentZoomSurvivesPresentingViewRedraw() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(SessionSummary.self, from: Data(#"{"session_id":"lightbox-test","title":"Image"}"#.utf8))
        let item = ChatAttachmentPreviewItem(message: MessageAttachment(name: "image.png", isImage: true), localData: imageData)
        let model = ChatAttachmentPreviewViewModel(session: session, server: server, item: item)
        await model.load()
        try assertZoomSurvivesRedraw { revision in
            ChatAttachmentImageLightbox(session: session, server: self.server, item: item, viewModel: model,
                onAPIError: { _ in XCTFail("Unexpected attachment error at redraw \(revision)") })
        }
    }

    private func assertZoomSurvivesRedraw<Content: View>(_ content: (Int) -> Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content(0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(lightboxScrollView(in: host.view))
        scroll.layoutIfNeeded()
        scroll.setZoomScale(2, animated: false)
        XCTAssertEqual(scroll.zoomScale, 2)

        host.rootView = content(1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertTrue(lightboxScrollView(in: host.view) === scroll)
        XCTAssertEqual(scroll.zoomScale, 2, "An unrelated redraw must not refit the loaded image")
    }
}

@MainActor
private func lightboxScrollView(in view: UIView) -> ZoomableScrollView? {
    if let scroll = view as? ZoomableScrollView { return scroll }
    return view.subviews.lazy.compactMap { lightboxScrollView(in: $0) }.first
}


private final class LightboxImageURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAHklEQVR4nGNgaPhPHTRq0KhBowaNGjRq0KhBA28QAELFXe7bxBBpAAAAAElFTkSuQmCC")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
