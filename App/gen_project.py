#!/usr/bin/env python3
"""Generates MetalCAD.xcodeproj/project.pbxproj + the shared scheme.

Single app target, no SPM: the app sources AND all MetalCADKit sources
are compiled into the one module (the kit files only import Foundation,
so no `import MetalCADKit` anywhere).

Run from anywhere: paths resolve relative to this script.
"""
import hashlib
import os

BASE = os.path.dirname(os.path.abspath(__file__))
APP = "MetalCAD"

def _swift_files(folder):
    """All .swift files in a folder, sorted for a stable project file."""
    try:
        return sorted(f for f in os.listdir(folder) if f.endswith(".swift"))
    except OSError:
        return []


# App sources: glob the app folder so a new view file is picked up
# automatically instead of silently missing from the build.
APP_FILES = _swift_files(os.path.join(BASE, APP)) or [
    "ContentView.swift",
    "DiagnosticsView.swift",
    "DocumentsView.swift",
    "EditorView.swift",
    "MetalCADApp.swift",
    "SceneKitView.swift",
    "SketchEditorView.swift",
]
# Kit sources: glob the kit folder — v2 added CSG.swift and Faces.swift,
# and a hard-coded list silently dropped them from the app target.
KIT_GROUP_PATH = "../MetalCADKit/Sources/MetalCADKit"
KIT_FILES = _swift_files(os.path.join(BASE, KIT_GROUP_PATH)) or [
    "CSG.swift",
    "Document.swift",
    "Errors.swift",
    "Faces.swift",
    "IO.swift",
    "MCLog.swift",
    "Math.swift",
    "Mesh.swift",
    "Sketch.swift",
    "Solver.swift",
    "Tessellation.swift",
    "Threads.swift",
]


def uuid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


# ---- UUIDs ----
proj_uuid = uuid("proj")
target_uuid = uuid("target")
app_ref = uuid("app_ref")
infoplist_ref = uuid("infoplist")
assets_ref = uuid("assets_ref")
assets_build = uuid("assets_build")
group_main = uuid("group_main")
group_kit = uuid("group_kit")
group_products = uuid("group_products")
group_root = uuid("group_root")
src_phase = uuid("src_phase")
res_phase = uuid("res_phase")
fw_phase = uuid("fw_phase")
proj_config_list = uuid("proj_config_list")
tgt_config_list = uuid("tgt_config_list")
proj_debug = uuid("proj_debug")
proj_release = uuid("proj_release")
tgt_debug = uuid("tgt_debug")
tgt_release = uuid("tgt_release")

file_refs = {f: uuid("fileref_" + f) for f in APP_FILES}
build_files = {f: uuid("buildfile_" + f) for f in APP_FILES}
kit_refs = {f: uuid("kitref_" + f) for f in KIT_FILES}
kit_builds = {f: uuid("kitbuild_" + f) for f in KIT_FILES}

objects = []

# PBXBuildFile
for f in APP_FILES:
    objects.append(f"\t\t{build_files[f]} = {{isa = PBXBuildFile; fileRef = {file_refs[f]}; }};")
for f in KIT_FILES:
    objects.append(f"\t\t{kit_builds[f]} = {{isa = PBXBuildFile; fileRef = {kit_refs[f]}; }};")
objects.append(f"\t\t{assets_build} = {{isa = PBXBuildFile; fileRef = {assets_ref}; }};")

# PBXFileReference
for f in APP_FILES:
    objects.append(f'\t\t{file_refs[f]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
for f in KIT_FILES:
    objects.append(f'\t\t{kit_refs[f]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
objects.append(f'\t\t{app_ref} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
objects.append(f'\t\t{infoplist_ref} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
objects.append(f'\t\t{assets_ref} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')

# PBXGroup
objects.append(f'''\t\t{group_root} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{group_main},
\t\t\t\t{group_kit},
\t\t\t\t{group_products},
\t\t\t\t{assets_ref},
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};''')
objects.append(f'''\t\t{group_main} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(chr(9)*4 + file_refs[f] + "," for f in APP_FILES)}
\t\t\t\t{infoplist_ref},
\t\t\t);
\t\t\tpath = {APP};
\t\t\tsourceTree = "<group>";
\t\t}};''')
objects.append(f'''\t\t{group_kit} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(chr(9)*4 + kit_refs[f] + "," for f in KIT_FILES)}
\t\t\t);
\t\t\tname = MetalCADKit;
\t\t\tpath = "{KIT_GROUP_PATH}";
\t\t\tsourceTree = "<group>";
\t\t}};''')
objects.append(f'''\t\t{group_products} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{app_ref},
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};''')

# PBXNativeTarget
objects.append(f'''\t\t{target_uuid} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {tgt_config_list};
\t\t\tbuildPhases = (
\t\t\t\t{src_phase},
\t\t\t\t{fw_phase},
\t\t\t\t{res_phase},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {APP};
\t\t\tproductName = {APP};
\t\t\tproductReference = {app_ref};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};''')

# PBXProject
objects.append(f'''\t\t{proj_uuid} = {{
\t\t\tisa = PBXProject;
\t\t\tbuildConfigurationList = {proj_config_list};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {group_root};
\t\t\tproductRefGroup = {group_products};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_uuid},
\t\t\t);
\t\t}};''')

# Phases
all_builds = [build_files[f] for f in APP_FILES] + [kit_builds[f] for f in KIT_FILES]
objects.append(f'''\t\t{src_phase} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(chr(9)*4 + b + "," for b in all_builds)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')
objects.append(f'''\t\t{fw_phase} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')
objects.append(f'''\t\t{res_phase} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{assets_build},
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')


# Configurations
def xcconfig(uid, configname, settings):
    lines = [f'\t\t{uid} = {{', '\t\t\tisa = XCBuildConfiguration;']
    lines.append('\t\t\tbuildSettings = {')
    for k, v in settings.items():
        lines.append(f'\t\t\t\t{k} = {v};')
    lines.append('\t\t\t};')
    lines.append(f'\t\t\tname = {configname};')
    lines.append('\t\t};')
    return '\n'.join(lines)


proj_settings = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_TESTABILITY": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "MTL_FAST_MATH": "YES",
    "ONLY_ACTIVE_ARCH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
tgt_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "14",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": '"MetalCAD/Info.plist"',
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "MARKETING_VERSION": "1.14",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.user.metalcad",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_STRICT_CONCURRENCY": "minimal",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"2"',
}

objects.append(xcconfig(proj_debug, "Debug", proj_settings))
objects.append(xcconfig(proj_release, "Release", {**proj_settings, "COPY_PHASE_STRIP": "YES", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "ENABLE_TESTABILITY": "NO", "ONLY_ACTIVE_ARCH": "NO"}))
objects.append(xcconfig(tgt_debug, "Debug", tgt_settings))
objects.append(xcconfig(tgt_release, "Release", {**tgt_settings, "COPY_PHASE_STRIP": "YES", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"'}))

objects.append(f'''\t\t{proj_config_list} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{proj_debug},
\t\t\t\t{proj_release},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''')
objects.append(f'''\t\t{tgt_config_list} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{tgt_debug},
\t\t\t\t{tgt_release},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''')

pbxproj = f'''// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{
{chr(10).join(objects)}
\t}};
\trootObject = {proj_uuid};
}}
'''

proj_dir = os.path.join(BASE, f"{APP}.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
    f.write(pbxproj)
print(f"Wrote {APP}.xcodeproj/project.pbxproj "
      f"({len(APP_FILES)} app + {len(KIT_FILES)} kit sources)")

# Sanity: the project wires Assets.xcassets + AppIcon into the app
# target, but actool can only compile an icon if the .appiconset on
# disk actually contains image payloads. A catalog whose images never
# made it into the tree (e.g. filtered out of a push) builds green
# yet ships an app with no icon — shout in the log instead.
_icon_dir = os.path.join(BASE, "Assets.xcassets", "AppIcon.appiconset")
_icon_imgs = ([f for f in os.listdir(_icon_dir)
               if f.lower().endswith((".png", ".jpg", ".jpeg", ".pdf"))]
              if os.path.isdir(_icon_dir) else [])
if not _icon_imgs:
    print("WARNING: AppIcon.appiconset has NO image files on disk — "
          "actool will produce no app icon. Check that the icon "
          "payload is present in the tree being built.")

# ---- Shared scheme ----
buildable_ref = f'''<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_uuid}"
               BuildableName = "{APP}.app"
               BlueprintName = "{APP}"
               ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>'''

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1430"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      runPostActionsOnFailure = "NO">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {buildable_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.AppExtensionToLLDB.Platform"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.AppExtensionToLLDB.Platform"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.AppExtensionToLLDB.Platform"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.AppExtensionToLLDB.Platform"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {buildable_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {buildable_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''

scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
with open(os.path.join(scheme_dir, f"{APP}.xcscheme"), "w") as f:
    f.write(scheme)
print(f"Wrote {APP}.xcodeproj/xcshareddata/xcschemes/{APP}.xcscheme")
