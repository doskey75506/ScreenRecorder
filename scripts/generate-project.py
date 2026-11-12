#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from the checked-in Swift sources."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(key, **fields):
    identifier = uid(key)
    objects[identifier] = fields
    return identifier


def configurations(name, extra):
    configs = []
    for mode in ("Debug", "Release"):
        settings = {
            "MACOSX_DEPLOYMENT_TARGET": "15.0", "SDKROOT": "macosx",
            "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
            "SWIFT_COMPILATION_MODE": "singlefile" if mode == "Debug" else "wholemodule",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym",
            "ONLY_ACTIVE_ARCH": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            **extra,
        }
        if mode == "Debug":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            settings["ENABLE_TESTABILITY"] = "YES"
        configs.append(add(f"{name}-{mode}", isa="XCBuildConfiguration", name=mode, buildSettings=settings))
    return add(f"{name}-configs", isa="XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


def sources(module):
    refs, builds = [], []
    for path in sorted((ROOT / "Sources" / module).glob("*.swift")):
        ref = add(str(path.relative_to(ROOT)), isa="PBXFileReference", lastKnownFileType="sourcecode.swift",
                  path=str(path.relative_to(ROOT)), sourceTree="SOURCE_ROOT")
        refs.append(ref)
        builds.append(add("build-" + path.name, isa="PBXBuildFile", fileRef=ref))
    return refs, add(module + "-sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647",
                     files=builds, runOnlyForDeploymentPostprocessing="0")


core_refs, core_sources = sources("RecorderCore")
app_refs, app_sources = sources("ScreenRecorder")
core_product = add("core-product", isa="PBXFileReference", explicitFileType="archive.ar", path="libRecorderCore.a",
                   sourceTree="BUILT_PRODUCTS_DIR")
app_product = add("app-product", isa="PBXFileReference", explicitFileType="wrapper.application", path="ScreenRecorder.app",
                  sourceTree="BUILT_PRODUCTS_DIR")
core = add("core", isa="PBXNativeTarget", name="RecorderCore", productName="RecorderCore",
           productType="com.apple.product-type.library.static", productReference=core_product,
           buildConfigurationList=configurations("core", {
               "PRODUCT_NAME": "$(TARGET_NAME)", "DEFINES_MODULE": "YES",
               "SWIFT_INSTALL_OBJC_HEADER": "NO", "SKIP_INSTALL": "YES",
           }), buildPhases=[core_sources], dependencies=[], buildRules=[])
proxy = add("core-proxy", isa="PBXContainerItemProxy", containerPortal=uid("project"), proxyType="1",
            remoteGlobalIDString=core, remoteInfo="RecorderCore")
dependency = add("core-dependency", isa="PBXTargetDependency", target=core, targetProxy=proxy)
link = add("core-link", isa="PBXBuildFile", fileRef=core_product)
frameworks = add("app-frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647",
                 files=[link], runOnlyForDeploymentPostprocessing="0")
icon = add("app-icon", isa="PBXFileReference", lastKnownFileType="image.icns", path="Config/AppIcon.icns", sourceTree="SOURCE_ROOT")
icon_build = add("app-icon-build", isa="PBXBuildFile", fileRef=icon)
resources = add("app-resources", isa="PBXResourcesBuildPhase", buildActionMask="2147483647",
                files=[icon_build], runOnlyForDeploymentPostprocessing="0")
app = add("app", isa="PBXNativeTarget", name="ScreenRecorder", productName="ScreenRecorder",
          productType="com.apple.product-type.application", productReference=app_product,
          buildConfigurationList=configurations("app", {
              "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "local.screenrecorder.app",
              "INFOPLIST_FILE": "Config/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
              "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-",
              "CODE_SIGN_ENTITLEMENTS": "Config/ScreenRecorder.entitlements",
              "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "NO",
              "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
          }), buildPhases=[app_sources, frameworks, resources], dependencies=[dependency], buildRules=[])
products = add("products", isa="PBXGroup", name="Products", children=[core_product, app_product], sourceTree="<group>")
main = add("main", isa="PBXGroup", children=core_refs + app_refs + [icon, products], sourceTree="<group>")
project = add("project", isa="PBXProject", attributes={"LastUpgradeCheck": "1640"},
              buildConfigurationList=configurations("project", {}), compatibilityVersion="Xcode 14.0",
              developmentRegion="en", knownRegions=["en", "zh-Hans", "Base"],
              mainGroup=main, productRefGroup=products, projectDirPath="", projectRoot="", targets=[core, app])


def encode(value, depth=0):
    tab = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(f"{tab}\t{json.dumps(k)} = {encode(v, depth + 1)};\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(item, depth) for item in value) + ")"
    return json.dumps(str(value), ensure_ascii=False)


directory = ROOT / "ScreenRecorder.xcodeproj"
directory.mkdir(exist_ok=True)
payload = dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(payload) + "\n")
schemes = directory / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="ScreenRecorder.app" BlueprintName="ScreenRecorder" ReferencedContainer="container:ScreenRecorder.xcodeproj"/>'
(schemes / "ScreenRecorder.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated ScreenRecorder.xcodeproj")
