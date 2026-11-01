load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AgentgramIntro",
    module_name = "AgentgramIntro",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SSignalKit",
        "//submodules/RMIntro:RMIntro",
        "//submodules/AppBundle:AppBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)
