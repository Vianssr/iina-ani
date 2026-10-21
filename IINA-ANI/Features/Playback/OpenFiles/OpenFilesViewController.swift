//
//  OpenFilesViewController.swift
//  iina+
//
//  Created by xjbeta on 2019/6/11.
//  Copyright © 2019 xjbeta. All rights reserved.
//

import Cocoa

class OpenFilesViewController: NSViewController {
    @IBOutlet weak var videoTextField: NSTextField!
    @IBOutlet weak var danmakuTextField: NSTextField!
    
    @IBOutlet weak var videoButton: NSButton!
    @IBOutlet weak var danmakuButton: NSButton!
    
    @IBAction func select(_ sender: NSButton) {
        guard let window = view.window else { return }
        
        panel.beginSheetModal(for: window) { [weak self] in
            guard $0 == .OK, let url = self?.panel.url else {
                return
            }
            switch sender {
            case self?.videoButton:
                self?.videoURL = url
                self?.videoTextField.stringValue = url.lastPathComponent
            case self?.danmakuButton:
                self?.danmakuURL = url
                self?.danmakuTextField.stringValue = url.lastPathComponent
            default:
                break
            }
        }
    }
    
    @IBAction func cancel(_ sender: NSButton) {
        view.window?.close()
    }
    
    @IBAction func open(_ sender: NSButton) {
        Task { await openFiles() }
    }

    func openFiles() async {
        do {
            var json = try await getVideo()
            json = try await getDanmaku(json)
            guard let key = json.videos.max(by: { $0.value.quality < $1.value.quality })?.key else {
                throw VideoGetError.notFountData
            }
            json = try await AppServices.current.decoder.prepareVideoUrl(json, key)
            let id = json.uuid
            try await AppServices.current.player.openWithPlayer(json, key)
            NotificationCenter.default.post(name: .loadDanmaku, object: nil, userInfo: ["id": id])
            view.window?.close()
        } catch is CancellationError {
            return
        } catch {
            presentError(error)
        }
    }
    
    var videoURL: URL?
    var danmakuURL: URL?
    
    enum BilibiliIdType: String {
        case ep
        case ss
        case bv = "BV"
        case av
    }
    
    lazy var panel: NSOpenPanel = {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.canChooseFiles = true
        return p
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        videoButton.setFunctionIcon(.folder)
        videoButton.setAccessibilityLabel(String(localized: "Choose Video File"))
        danmakuButton.setFunctionIcon(.danmaku)
        danmakuButton.setAccessibilityLabel(String(localized: "Choose Danmaku File"))
    }
    
    func formatBiliUrl(_ string: String) -> BilibiliUrl? {
        var string = string
        
        guard string.count > 2 else {
            return nil
        }
        
        if let type = BilibiliIdType(rawValue: String(string.prefix(2))) {
            switch type {
            case .av, .bv:
                string = "https://www.bilibili.com/video/" + string
            case .ep, .ss:
                string = "https://www.bilibili.com/bangumi/play/" + string
            }
        }
        
        return BilibiliUrl(url: string)
    }
    
    func getVideo() async throws -> YouGetJSON {
        let string = videoTextField.stringValue
        let input: String
        if let videoURL {
            input = videoURL.absoluteString
        } else {
            guard let bUrl = formatBiliUrl(string) else { throw OpenFilesError.invalidVideoUrl }
            input = bUrl.fUrl
        }
        let decoder = AppServices.current.decoder
        let selection = try await decoder.selection(for: input)
        return try await decoder.resolve(selection)
    }
    
    func getDanmaku(_ yougetJSON: YouGetJSON) async throws -> YouGetJSON {
        var json = yougetJSON
        guard danmakuURL == nil else {
            let url = danmakuURL!
            let data = FileManager.default.contents(atPath: url.path)
			VideoDecoder.saveDMFile(data, with: json.uuid)
			return json
        }
        
        let s = danmakuTextField.stringValue
        
        if s == "" {
			return json
        }
        
        guard let bUrl = formatBiliUrl(s) else {
            throw OpenFilesError.invalidDanmakuUrl
        }
		
		
		let re = try await Bilibili.shared.video.bilibiliPrepareID(bUrl.fUrl)
		
		json.id = re.id
		json.bvid = re.bvid
		json.duration = re.duration
		
		try await AppServices.current.player.prepareDanmakuFile(yougetJSON: json, id: json.uuid)
		
		return json
    }
    
    enum OpenFilesError: LocalizedError {
        case invalidVideoString
        case invalidVideoUrl
        case invalidDanmakuString
        case invalidDanmakuUrl
        case unsupported

        var errorDescription: String? {
            switch self {
            case .invalidVideoString, .invalidVideoUrl:
                return String(localized: "Enter a valid video URL or choose a video file.")
            case .invalidDanmakuString, .invalidDanmakuUrl:
                return String(localized: "Enter a valid danmaku URL or choose a danmaku file.")
            case .unsupported:
                return String(localized: "This video or danmaku format is not supported.")
            }
        }
    }
}

extension OpenFilesViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        switch control {
        case videoTextField:
            videoURL = nil
        case danmakuTextField:
            danmakuURL = nil
        default:
            return false
        }
        
        return true
    }
}
