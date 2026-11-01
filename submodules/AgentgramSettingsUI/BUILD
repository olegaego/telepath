load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AgentgramSettingsUI",
    module_name = "AgentgramSettingsUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AppBundle:AppBundle",
        "//submodules/SolidRoundedButtonNode:SolidRoundedButtonNode",
        "//submodules/AgentgramCore",
        "//submodules/TelegramUI/Components/ThreadedBotSessions",
        "//submodules/TelegramUI/Components/Superfolders",
        "//submodules/ChatListUI:ChatListUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
