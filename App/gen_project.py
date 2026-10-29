#!/usr/bin/env python3
"""Generates MetalCAD.xcodeproj/project.pbxproj + the shared scheme.

App target + CascadeKit static library target, no SPM: the app
sources AND all MetalCADKit sources are compiled into the one module
(the kit files only import Foundation, so no `import MetalCADKit`
anywhere).

CascadeKit (the implant, 2026-10-28) is the Open CASCADE engine: the
OCCT subset sources + the C façade from the cascade-ios repo. That
repo is the engine's source of truth — CI clones it, pinned to one
commit (see .github/workflows/build-ipa.yml), into <repo>/cascade-
engine before running this script, so paths below resolve relative
to this script as ../cascade-engine/... . Set CASCADE_ENGINE_DIR to
override the location.

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


# ---- Cascade engine (OCCT subset + façade), from the pinned
# cascade-ios checkout. Collected exactly the way cascade-ios's own
# generator collects them (same extensions, same generated header).
ENGINE_REL = os.environ.get("CASCADE_ENGINE_DIR", "../cascade-engine")
ENGINE_ABS = os.path.normpath(os.path.join(BASE, ENGINE_REL))


def _engine_collect():
    sources, headers, header_dirs = [], [], set()
    src_root = os.path.join(ENGINE_ABS, "OCCT", "src")
    if os.path.isdir(src_root):
        for dirpath, dirnames, filenames in os.walk(src_root):
            dirnames.sort()
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, BASE)
                ext = fn.rsplit(".", 1)[-1]
                if ext in ("cxx", "c", "cpp"):
                    sources.append(rel)
                elif ext in ("hxx", "lxx", "pxx", "gxx", "h"):
                    headers.append(rel)
                    header_dirs.add(os.path.relpath(dirpath, BASE))
    gen = os.path.join(ENGINE_ABS, "OCCT", "generated", "Standard_Version.hxx")
    if os.path.isfile(gen):
        headers.append(os.path.relpath(gen, BASE))
        header_dirs.add(os.path.relpath(os.path.dirname(gen), BASE))
    facade_dir = os.path.join(ENGINE_ABS, "Facade")
    facade_cpp = os.path.join(facade_dir, "occt_facade.cpp")
    facade_h = os.path.join(facade_dir, "occt_facade.h")
    if os.path.isfile(facade_cpp):
        sources.append(os.path.relpath(facade_cpp, BASE))
    if os.path.isfile(facade_h):
        headers.append(os.path.relpath(facade_h, BASE))
    if os.path.isdir(facade_dir):
        header_dirs.add(os.path.relpath(facade_dir, BASE))
    return sorted(sources), sorted(headers), sorted(header_dirs)


ENGINE_SOURCES, ENGINE_HEADERS, ENGINE_HEADER_DIRS = _engine_collect()
ENGINE_LICENSES = [
    os.path.relpath(os.path.join(ENGINE_ABS, "OCCT", f), BASE)
    for f in ("LICENSE_LGPL_21.txt", "OCCT_LGPL_EXCEPTION.txt")
    if os.path.isfile(os.path.join(ENGINE_ABS, "OCCT", f))
]
FACADE_REL = os.path.relpath(os.path.join(ENGINE_ABS, "Facade"), BASE)

ENGINE_FILETYPE = {
    "cxx": "sourcecode.cpp.cpp", "cpp": "sourcecode.cpp.cpp",
    "c": "sourcecode.c.c", "hxx": "sourcecode.cpp.h",
    "lxx": "sourcecode.cpp.h", "pxx": "sourcecode.cpp.h",
    "gxx": "sourcecode.cpp.h", "h": "sourcecode.c.h",
    "txt": "text",
}


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

# CascadeKit (engine library) UUIDs.
ck_target = uuid("ck_target")
ck_lib_ref = uuid("ck_lib_ref")
ck_src_phase = uuid("ck_src_phase")
ck_hdr_phase = uuid("ck_hdr_phase")
ck_fw_phase = uuid("ck_fw_phase")
ck_config_list = uuid("ck_config_list")
ck_debug = uuid("ck_debug")
ck_release = uuid("ck_release")
group_engine = uuid("group_engine")
app_dep = uuid("app_dep")
app_proxy = uuid("app_proxy")
ck_lib_build = uuid("ck_lib_build")
eng_refs = {p: uuid("engref_" + p) for p in ENGINE_SOURCES + ENGINE_HEADERS + ENGINE_LICENSES}
eng_src_builds = {p: uuid("engsrc_" + p) for p in ENGINE_SOURCES}
eng_hdr_builds = {p: uuid("enghdr_" + p) for p in ENGINE_HEADERS}
lic_builds = {p: uuid("licbuild_" + p) for p in ENGINE_LICENSES}

objects = []

# PBXBuildFile
for f in APP_FILES:
    objects.append(f"\t\t{build_files[f]} = {{isa = PBXBuildFile; fileRef = {file_refs[f]}; }};")
for f in KIT_FILES:
    objects.append(f"\t\t{kit_builds[f]} = {{isa = PBXBuildFile; fileRef = {kit_refs[f]}; }};")
objects.append(f"\t\t{assets_build} = {{isa = PBXBuildFile; fileRef = {assets_ref}; }};")
for p in ENGINE_SOURCES:
    objects.append(f"\t\t{eng_src_builds[p]} = {{isa = PBXBuildFile; fileRef = {eng_refs[p]}; }};")
for p in ENGINE_HEADERS:
    objects.append(f"\t\t{eng_hdr_builds[p]} = {{isa = PBXBuildFile; fileRef = {eng_refs[p]}; settings = {{ATTRIBUTES = (Project, ); }}; }};")
for p in ENGINE_LICENSES:
    objects.append(f"\t\t{lic_builds[p]} = {{isa = PBXBuildFile; fileRef = {eng_refs[p]}; }};")
objects.append(f"\t\t{ck_lib_build} = {{isa = PBXBuildFile; fileRef = {ck_lib_ref}; }};")

# PBXContainerItemProxy + PBXTargetDependency (app -> CascadeKit)
objects.append(f'''\t\t{app_proxy} = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {proj_uuid};
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {ck_target};
\t\t\tremoteInfo = CascadeKit;
\t\t}};''')
objects.append(f'''\t\t{app_dep} = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {ck_target};
\t\t\ttargetProxy = {app_proxy};
\t\t}};''')

# PBXFileReference
for f in APP_FILES:
    objects.append(f'\t\t{file_refs[f]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
for f in KIT_FILES:
    objects.append(f'\t\t{kit_refs[f]} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};')
for p in ENGINE_SOURCES + ENGINE_HEADERS + ENGINE_LICENSES:
    ext = p.rsplit(".", 1)[-1]
    objects.append(f'\t\t{eng_refs[p]} = {{isa = PBXFileReference; lastKnownFileType = {ENGINE_FILETYPE[ext]}; path = {p}; sourceTree = SOURCE_ROOT; }};')
objects.append(f'\t\t{ck_lib_ref} = {{isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libCascadeKit.a; sourceTree = BUILT_PRODUCTS_DIR; }};')
objects.append(f'\t\t{app_ref} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
objects.append(f'\t\t{infoplist_ref} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
objects.append(f'\t\t{assets_ref} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')

# PBXGroup
objects.append(f'''\t\t{group_root} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{group_main},
\t\t\t\t{group_kit},
\t\t\t\t{group_engine},
\t\t\t\t{group_products},
\t\t\t\t{assets_ref},
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};''')
objects.append(f'''\t\t{group_engine} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(chr(9)*4 + eng_refs[p] + "," for p in ENGINE_SOURCES + ENGINE_HEADERS + ENGINE_LICENSES)}
\t\t\t);
\t\t\tname = CascadeEngine;
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
\t\t\t\t{ck_lib_ref},
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
\t\t\t\t{app_dep},
\t\t\t);
\t\t\tname = {APP};
\t\t\tproductName = {APP};
\t\t\tproductReference = {app_ref};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};''')
objects.append(f'''\t\t{ck_target} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ck_config_list};
\t\t\tbuildPhases = (
\t\t\t\t{ck_src_phase},
\t\t\t\t{ck_fw_phase},
\t\t\t\t{ck_hdr_phase},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = CascadeKit;
\t\t\tproductName = CascadeKit;
\t\t\tproductReference = {ck_lib_ref};
\t\t\tproductType = "com.apple.product-type.library.static";
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
\t\t\t\t{ck_target},
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
\t\t\t\t{ck_lib_build},
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')
objects.append(f'''\t\t{res_phase} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{assets_build},
{chr(10).join(chr(9)*4 + lic_builds[p] + "," for p in ENGINE_LICENSES)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')
objects.append(f'''\t\t{ck_src_phase} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(chr(9)*4 + eng_src_builds[p] + "," for p in ENGINE_SOURCES)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')
objects.append(f'''\t\t{ck_fw_phase} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')
objects.append(f'''\t\t{ck_hdr_phase} = {{
\t\t\tisa = PBXHeadersBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(chr(9)*4 + eng_hdr_builds[p] + "," for p in ENGINE_HEADERS)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''')


# Configurations
def _q(s):
    # Quote a build-setting list item when it contains characters
    # outside Xcode's unquoted set (e.g. $(SRCROOT) has parens/$);
    # an unquoted offender makes the project unparseable.
    if s and all(c.isalnum() or c in "_./-" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def xcconfig(uid, configname, settings):
    lines = [f'\t\t{uid} = {{', '\t\t\tisa = XCBuildConfiguration;']
    lines.append('\t\t\tbuildSettings = {')
    for k, v in settings.items():
        if isinstance(v, list):
            lines.append(f'\t\t\t\t{k} = (')
            for item in v:
                lines.append(f'\t\t\t\t\t{_q(item)},')
            lines.append('\t\t\t\t);')
        else:
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
    "CURRENT_PROJECT_VERSION": "20",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "HEADER_SEARCH_PATHS": ["$(inherited)", f"$(SRCROOT)/{FACADE_REL}"],
    "INFOPLIST_FILE": '"MetalCAD/Info.plist"',
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "MARKETING_VERSION": "1.20",
    "OTHER_LDFLAGS": '"-lc++"',
    "PRODUCT_BUNDLE_IDENTIFIER": "com.user.metalcad",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_OBJC_BRIDGING_HEADER": '"MetalCAD/MetalCAD-Bridging-Header.h"',
    "SWIFT_STRICT_CONCURRENCY": "minimal",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"2"',
}

# CascadeKit settings replicate the proven cascade-ios build of the
# same sources (gnu++17, exceptions + RTTI on, OCCT's own defines).
ck_settings = {
    "ARCHS": "arm64",
    "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++17"',
    "DEFINES_MODULE": "NO",
    "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
    "GCC_ENABLE_CPP_RTTI": "YES",
    "GCC_PREPROCESSOR_DEFINITIONS": [
        "$(inherited)", "OCC_CONVERT_SIGNALS", "No_Exception",
        "OCCT_NO_PLUGINS", "NDEBUG",
    ],
    "HEADER_SEARCH_PATHS": ["$(inherited)"] + [f"$(SRCROOT)/{d}" for d in ENGINE_HEADER_DIRS],
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "PRODUCT_NAME": "CascadeKit",
    "SKIP_INSTALL": "YES",
}

objects.append(xcconfig(proj_debug, "Debug", proj_settings))
objects.append(xcconfig(proj_release, "Release", {**proj_settings, "COPY_PHASE_STRIP": "YES", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "ENABLE_TESTABILITY": "NO", "ONLY_ACTIVE_ARCH": "NO"}))
objects.append(xcconfig(tgt_debug, "Debug", tgt_settings))
objects.append(xcconfig(tgt_release, "Release", {**tgt_settings, "COPY_PHASE_STRIP": "YES", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"'}))
objects.append(xcconfig(ck_debug, "Debug", ck_settings))
objects.append(xcconfig(ck_release, "Release", ck_settings))
objects.append(f'''\t\t{ck_config_list} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ck_debug},
\t\t\t\t{ck_release},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''')

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

# Sanity: without the Cascade engine checkout the project references
# zero OCCT sources and the app cannot link its CascadeKit target —
# shout instead of failing mysteriously in xcodebuild. CI clones the
# pinned cascade-ios tree into ../cascade-engine first (see the
# workflow); locally, clone it there by hand.
if not ENGINE_SOURCES:
    print("WARNING: Cascade engine NOT found at "
          f"{ENGINE_ABS} — 0 OCCT sources wired into CascadeKit. "
          "Clone a-user-of-python/cascade-ios there (pinned commit "
          "in .github/workflows/build-ipa.yml) before building.")
else:
    print(f"Cascade engine: {len(ENGINE_SOURCES)} sources + "
          f"{len(ENGINE_HEADERS)} headers from {ENGINE_ABS}")

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
