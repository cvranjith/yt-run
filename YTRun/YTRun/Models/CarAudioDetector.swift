//
//  CarAudioDetector.swift
//  YTRun
//

import AVFoundation

enum CarAudioDetector {
    // Checks the phone's *current* audio output route for a car
    // connection: a real CarPlay session (which iOS reports with a
    // distinct `.carAudio` port type, no configuration needed), or a
    // plain Bluetooth device whose name matches `carDeviceName` (for cars
    // without CarPlay, which otherwise look identical to any other
    // Bluetooth accessory).
    static func isCarAudioActive(carDeviceName: String) -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs

        for output in outputs {
            if output.portType == .carAudio {
                return true
            }
            if !carDeviceName.isEmpty, output.portName.localizedCaseInsensitiveContains(carDeviceName) {
                return true
            }
        }
        return false
    }
}
