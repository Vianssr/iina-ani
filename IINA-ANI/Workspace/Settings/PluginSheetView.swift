//
//  PluginSheetView.swift
//  IINA+
//
//  Created by xjbeta on 2025/5/16.
//  Copyright © 2025 xjbeta. All rights reserved.
//

import SwiftUI

private struct PluginStepView<Content: View>: View {
    let stepNumber: Int
    let backgroundColor: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(stepNumber))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(backgroundColor, in: Circle())
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(backgroundColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PluginSheetView: View {
    
    @Binding var pluginSheet: Bool
    @State private var stepValue = 0
    @State private var installPluginTitle = ""
    
    var defaultColor = Color.gray
    
    enum PlistKeys: String {
        case systemEnable = "iinaEnablePluginSystem"
        case pluginEnable = "PluginEnabled.com.xjbeta.danmaku"
        case parseEnable = "enableIINAPLUSOptsParse"
        
        var domain: String {
            get {
                if self == .parseEnable {
                    let path = (try? IINAApp.pluginFolder() + ".preferences/") ?? ""
                    
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: path) {
                        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                    }
                    
                    return "'" + path + "com.xjbeta.danmaku.plist" + "'"
                } else {
                    return "com.colliderli.iina"
                }
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 12) {
                PluginStepView(stepNumber: 1, backgroundColor: stepValue > 0 ? .blue : defaultColor) {
                    Text(NSLocalizedString("PluginInstaller.enableSystemStep", comment: ""))
                    Spacer(minLength: 15)
                    if stepValue == 0 {
                        Button {
                            defaultsWrite(.systemEnable, boolValue: true)
                            initPluginStates()
                        } label: {
                            Text(NSLocalizedString("PluginInstaller.enableSystem", comment: ""))
                        }
                        .disabled(stepValue != 0)
                    }
                }
                PluginStepView(stepNumber: 2, backgroundColor: stepValue > 1 ? .green : defaultColor) {
                    Text(NSLocalizedString("PluginInstaller.installStep", comment: ""))
                    Spacer(minLength: 15)
                    if stepValue == 1 {
                        Button {
                            do {
                                let plugins = try IINAApp.listPlugins()
                                IINAApp.uninstallPlugins(plugins)
                                try IINAApp.installPlugin()
                            } catch let error {
                                Log(error)
                            }
                            
                            initPluginStates()
                        } label: {
                            Text(installPluginTitle)
                        }
                        .opacity(stepValue != 1 ? 0 : 1)
                    }
                }
                PluginStepView(stepNumber: 3, backgroundColor: stepValue > 2 ? .orange : defaultColor) {
                    Text(NSLocalizedString("PluginInstaller.enableDanmakuStep", comment: ""))
                    Spacer(minLength: 15)
                    if stepValue == 2 {
                        Button {
                            defaultsWrite(.pluginEnable, boolValue: true)
                            defaultsWrite(.parseEnable, stringValue: "1")
                            initPluginStates()
                        } label: {
                            Text(NSLocalizedString("PluginInstaller.enableDanmaku", comment: ""))
                        }
                        .disabled(stepValue != 2)
                    }
                }
            }
            
            if stepValue == 3 {
                Text(NSLocalizedString("PluginInstaller.tips", comment: ""))
            }
            
            Spacer(minLength: 15)
            
            HStack {
                Spacer()
                Button {
                    pluginSheet = false
                } label: {
                    Text("Cancel")
                        .frame(width: 65)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .onAppear {
            initPluginStates()
        }
    }
    
    

    
    func initPluginStates() {
        // reset
        
        // step2 button
//        installPluginTitle = ""
        
        
        stepValue = 0
        
        // plugin system
        guard getPluginSystemState() else {
            return
        }
        
        // danmaku plugin
        let pluginState = IINAApp.pluginState()
        
        var installState = false
        
        switch pluginState {
        case .ok(_):
            installPluginTitle = String(localized: "Install")
            installState = true
        case .needsUpdate(let plugin):
            installPluginTitle = String(localized: "Update \(plugin.version) to \(IINAApp.internalPluginVersion)")
        case .needsInstall:
            installPluginTitle = String(localized: "Install")
        case .newer(let plugin):
            installPluginTitle = String(localized: "\(plugin.version) is newer")
        case .isDev:
            installPluginTitle = String(localized: "Development Version")
            installState = true
        case .multiple:
            installPluginTitle = String(localized: "Update")
        case .error(let error):
            Log("list all plugins error \(error)")
            installPluginTitle = String(localized: "Error")
        }
        stepValue = 1
        guard installState else { return }
        
        // enable danmaku plugin
        let danmakuState = getDanmakuState()
        
        stepValue = 2
        guard danmakuState else { return }
        
        stepValue = 3
    }
    
    func getPluginSystemState() -> Bool {
        // defaults read com.colliderli.iina iinaEnablePluginSystem
        (defaultsRead(.systemEnable) ?? "0") == "1"
        
//        IINAApp.getBuildVersion()
    }
    
    
    func getDanmakuState() -> Bool {
        (defaultsRead(.pluginEnable) ?? "0") == "1"
        && (defaultsRead(.parseEnable) ?? "0") == "1"
    }
    
    func defaultsWrite(_ key: PlistKeys, stringValue: String) {
        let _ = Process.run(["/bin/bash", "-c", "defaults write \(key.domain) \(key.rawValue) \(stringValue)"])
    }
    
    func defaultsWrite(_ key: PlistKeys, boolValue: Bool) {
        let _ = Process.run(["/bin/bash", "-c", "defaults write \(key.domain) \(key.rawValue) -bool \(boolValue ? "true" : "false")"])
    }
    
    func defaultsRead(_ key: PlistKeys) -> String? {
        let (process, outText, errText) = Process.run(["/bin/bash", "-c", "defaults read \(key.domain) \(key.rawValue)"])
        
        guard process.terminationStatus == 0, let out = outText else {
            Log("outText: \(outText ?? "none")")
            Log("errText: \(errText ?? "none")")
            return nil
        }
        
        return out.replacingOccurrences(of: "\n", with: "")
    }
}

#Preview {
    PluginSheetView(pluginSheet: .init(get: {
        true
    }, set: { _ in
        
    }))
}
