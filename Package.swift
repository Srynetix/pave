// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT OR Apache-2.0
import PackageDescription

let package = Package(
    name: "Pave",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PaveApp", targets: ["PaveApp"]),
        .executable(name: "pave", targets: ["pave"]),
    ],
    targets: [
        // Pure logic: must not import AppKit / ApplicationServices.
        .target(name: "PaveCore"),
        // IPC protocol + Unix socket helpers, shared by the agent and the CLI (Foundation only).
        .target(name: "PaveIPC", dependencies: ["PaveCore"]),
        // Everything that talks to macOS (AX, event taps, IPC). Private APIs live in Private.swift only.
        .target(name: "PaveMac", dependencies: ["PaveCore", "PaveIPC"]),
        // The menu-bar agent, bundled as Pave.app by scripts/bundle.sh.
        .executableTarget(name: "PaveApp", dependencies: ["PaveMac"]),
        // CLI talking to the agent over a Unix socket.
        .executableTarget(name: "pave", dependencies: ["PaveCore", "PaveIPC"]),
        .testTarget(name: "PaveCoreTests", dependencies: ["PaveCore"]),
        .testTarget(name: "PaveIPCTests", dependencies: ["PaveIPC"]),
    ]
)
