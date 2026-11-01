load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ThreadedBotSessions",
    module_name = "ThreadedBotSessions",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
    ],
    visibility = [
        "//visibility:public",
    ],
)
