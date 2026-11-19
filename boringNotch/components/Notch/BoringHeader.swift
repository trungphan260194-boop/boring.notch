//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if (!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf] {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.screenshotButtonInNotch] {
                            Button(action: {
                                Task { @MainActor in
                                    vm.close(force: true)
                                    try? await Task.sleep(for: .milliseconds(90))
                                    ZaloScreenshotCoordinator.shared.startCapture()
                                }
                            }) {
                                Capsule()
                                    .fill(Color.white.opacity(0.10))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        Image(systemName: "camera.viewfinder")
                                            .foregroundColor(.white)
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Chụp màn hình & Ghi chú (⌥⌘A)")
                        }
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                vm.isPinned.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(vm.isPinned ? Color(red: 0.0, green: 0.41, blue: 1.0) : Color.white.opacity(0.10))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                                        .foregroundColor(.white)
                                        .font(.system(size: 11, weight: .semibold))
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(vm.isPinned ? "Bỏ ghim tai thỏ" : "Ghim giữ tai thỏ mở")
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                            }) {
                                Capsule()
                                    .fill(Color.white.opacity(0.10))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .imageScale(.medium)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Cài đặt")
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
