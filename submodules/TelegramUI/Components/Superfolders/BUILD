load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "Superfolders",
    module_name = "Superfolders",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/TelegramUI/Components/EmojiTextAttachmentView:EmojiTextAttachmentView",
    ],
    visibility = [
        "//visibility:public",
    ],
)
