#!/usr/bin/env python3
"""
生成 ios/PicImpact.xcodeproj。

为什么不手写 project.pbxproj：那是一份由 Xcode 维护的、充满不透明 UUID 的文件，
手改极易出错且无法审查。把生成过程脚本化之后：
  - 工程文件可以随时重新生成，不担心被 Xcode 改坏
  - 依赖关系、构建设置都在这里一目了然，diff 时可读

用法：python3 scripts/ios-project.py
校验：xcodebuild -project ios/PicImpact.xcodeproj -list
"""
from __future__ import annotations

import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
PROJECT_NAME = "PicImpact"
APP_DIR = IOS / PROJECT_NAME
PACKAGE_RELATIVE = "PicImpactKit"  # 相对于工程文件所在目录


def uid(*parts: str) -> str:
    """由内容派生稳定的 24 位十六进制 ID（同一份输入永远得到同一个 ID）"""
    digest = hashlib.sha1("::".join(parts).encode()).hexdigest().upper()
    return digest[:24]


def main() -> None:
    swift_sources = sorted(p.name for p in APP_DIR.glob("*.swift"))
    # 资源包含普通文件，也包含 .xcassets 这类**目录**（AppIcon 就在里面，
    # 原来的 p.is_file() 会把目录整个漏掉）。
    resources = sorted(
        str(p.relative_to(APP_DIR))
        for p in (APP_DIR / "Resources").glob("*")
        if p.is_file() or p.suffix == ".xcassets"
    )

    project_id = uid("project", PROJECT_NAME)
    target_id = uid("target", PROJECT_NAME)
    product_ref_id = uid("product", PROJECT_NAME)
    main_group_id = uid("group", "main")
    app_group_id = uid("group", "app")
    products_group_id = uid("group", "products")
    sources_phase_id = uid("phase", "sources")
    resources_phase_id = uid("phase", "resources")
    frameworks_phase_id = uid("phase", "frameworks")
    config_list_project_id = uid("configlist", "project")
    config_list_target_id = uid("configlist", "target")
    package_ref_id = uid("package", PACKAGE_RELATIVE)
    package_product_id = uid("packageproduct", "PicImpactKit")

    file_refs = {}
    for name in swift_sources:
        file_refs[name] = uid("file", name)
    for rel in resources:
        file_refs[rel] = uid("file", rel)

    # ---------------- PBXBuildFile ----------------
    build_files = []
    sources_build_ids = []
    for name in swift_sources:
        bid = uid("buildfile", name)
        sources_build_ids.append(bid)
        build_files.append(
            f"\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[name]} /* {name} */; }};"
        )
    resources_build_ids = []
    for rel in resources:
        bid = uid("buildfile", rel)
        resources_build_ids.append(bid)
        build_files.append(
            f"\t\t{bid} /* {rel} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_refs[rel]} /* {rel} */; }};"
        )
    # 本地 Swift 包产物
    package_build_id = uid("buildfile", "PicImpactKit")
    build_files.append(
        f"\t\t{package_build_id} /* PicImpactKit in Frameworks */ = {{isa = PBXBuildFile; "
        f"productRef = {package_product_id} /* PicImpactKit */; }};"
    )

    # ---------------- PBXFileReference ----------------
    def file_type(rel: str) -> str:
        """按后缀决定 Xcode 的文件类型 —— 类型错了 actool 不会处理资源目录。"""
        if rel.endswith(".xcassets"):
            return "folder.assetcatalog"
        if rel.endswith(".xcstrings"):
            return "text.json.xcstrings"
        if rel.endswith(".json"):
            return "text.json"
        return "file"

    file_reference_lines = []
    for name in swift_sources:
        file_reference_lines.append(
            f"\t\t{file_refs[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {name}; sourceTree = \"<group>\"; }};"
        )
    for rel in resources:
        file_reference_lines.append(
            f"\t\t{file_refs[rel]} /* {rel} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type(rel)}; "
            f"path = {rel}; sourceTree = \"<group>\"; }};"
        )
    file_reference_lines.append(
        f"\t\t{product_ref_id} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = "
        f'wrapper.application; includeInIndex = 0; path = "大福映画.app"; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )

    pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 60;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_reference_lines)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{frameworks_phase_id} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{package_build_id} /* PicImpactKit in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{main_group_id} = {{
			isa = PBXGroup;
			children = (
				{app_group_id} /* {PROJECT_NAME} */,
				{products_group_id} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{app_group_id} /* {PROJECT_NAME} */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(f"\t\t\t\t{file_refs[name]} /* {name} */," for name in swift_sources)}
{chr(10).join(f"\t\t\t\t{file_refs[rel]} /* {rel} */," for rel in resources)}
			);
			path = {PROJECT_NAME};
			sourceTree = "<group>";
		}};
		{products_group_id} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{product_ref_id} /* {PROJECT_NAME}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{target_id} /* {PROJECT_NAME} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {config_list_target_id} /* Build configuration list for PBXNativeTarget "{PROJECT_NAME}" */;
			buildPhases = (
				{sources_phase_id} /* Sources */,
				{frameworks_phase_id} /* Frameworks */,
				{resources_phase_id} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = {PROJECT_NAME};
			packageProductDependencies = (
				{package_product_id} /* PicImpactKit */,
			);
			productName = {PROJECT_NAME};
			productReference = {product_ref_id} /* {PROJECT_NAME}.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project_id} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2650;
				LastUpgradeCheck = 2650;
				TargetAttributes = {{
					{target_id} = {{
						CreatedOnToolsVersion = 26.5;
					}};
				}};
			}};
			buildConfigurationList = {config_list_project_id} /* Build configuration list for PBXProject "{PROJECT_NAME}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = zh;
			hasScannedForEncodings = 0;
			knownRegions = (
				zh,
				en,
				ja,
				"zh-Hant",
				Base,
			);
			mainGroup = {main_group_id};
			packageReferences = (
				{package_ref_id} /* XCLocalSwiftPackageReference "{PACKAGE_RELATIVE}" */,
			);
			productRefGroup = {products_group_id} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target_id} /* {PROJECT_NAME} */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_phase_id} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(f"\t\t\t\t{bid} /* {rel} in Resources */," for bid, rel in zip(resources_build_ids, resources))}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_phase_id} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(f"\t\t\t\t{bid} /* {name} in Sources */," for bid, name in zip(sources_build_ids, swift_sources))}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{uid('buildconfig', 'project', 'debug')} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 6.0;
			}};
			name = Debug;
		}};
		{uid('buildconfig', 'project', 'release')} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 6.0;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{uid('buildconfig', 'target', 'debug')} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = VX3SCAKB5K;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "大福映画";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.magazines-and-newspapers";
				INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "保存照片到你的相册";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.boxz.felina;
				PRODUCT_NAME = "大福映画";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{uid('buildconfig', 'target', 'release')} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = VX3SCAKB5K;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "大福映画";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.magazines-and-newspapers";
				INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "保存照片到你的相册";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.boxz.felina;
				PRODUCT_NAME = "大福映画";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{config_list_project_id} /* Build configuration list for PBXProject "{PROJECT_NAME}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{uid('buildconfig', 'project', 'debug')} /* Debug */,
				{uid('buildconfig', 'project', 'release')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{config_list_target_id} /* Build configuration list for PBXNativeTarget "{PROJECT_NAME}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{uid('buildconfig', 'target', 'debug')} /* Debug */,
				{uid('buildconfig', 'target', 'release')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{package_ref_id} /* XCLocalSwiftPackageReference "{PACKAGE_RELATIVE}" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = {PACKAGE_RELATIVE};
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{package_product_id} /* PicImpactKit */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = PicImpactKit;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {project_id} /* Project object */;
}}
"""

    project_dir = IOS / f"{PROJECT_NAME}.xcodeproj"
    project_dir.mkdir(parents=True, exist_ok=True)
    (project_dir / "project.pbxproj").write_text(pbxproj)

    # 共享 scheme，便于 `xcodebuild -scheme PicImpact` 直接可用
    schemes_dir = project_dir / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    (schemes_dir / f"{PROJECT_NAME}.xcscheme").write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2650" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{PROJECT_NAME}.app"
               BlueprintName = "{PROJECT_NAME}"
               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{PROJECT_NAME}.app"
            BlueprintName = "{PROJECT_NAME}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{PROJECT_NAME}.app"
            BlueprintName = "{PROJECT_NAME}"
            ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
    )

    print(f"已生成 {project_dir.relative_to(ROOT)}")
    print(f"  Swift 源文件：{len(swift_sources)}（{', '.join(swift_sources)}）")
    print(f"  资源：{len(resources)}（{', '.join(resources) if resources else '无'}）")
    print(f"  本地包依赖：{PACKAGE_RELATIVE}")


if __name__ == "__main__":
    main()
