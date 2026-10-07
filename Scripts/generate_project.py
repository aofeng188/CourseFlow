#!/usr/bin/env python3
"""Generate a dependency-free, reproducible Xcode project (Xcode 16+ folder sync)."""
from pathlib import Path
import hashlib, json, plistlib

root = Path(__file__).resolve().parent.parent
# Keep the personal-device trial in sync with the main app's permission strings.
# It deliberately has no app extension, App Group, CloudKit or push entitlement.
trial_info = plistlib.loads((root/'Config/App-Info.plist').read_bytes())
trial_info.update({'TrialBuild': True, 'CloudSyncEnabled': 'NO',
                   'NSSupportsLiveActivities': False, 'UIBackgroundModes': ['fetch']})
trial_info['CFBundleURLTypes'] = [{'CFBundleURLName': 'com.courseflow.app.trial',
                                  'CFBundleURLSchemes': ['courseflow-trial']}]
(root/'Config/Trial-Info.plist').write_bytes(plistlib.dumps(trial_info, sort_keys=False))
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(object_key, **fields):
    key = uid(object_key); objects[key] = fields; return key
def quote(value):
    if isinstance(value, dict): return '{ ' + ' '.join(quote(k) + ' = ' + quote(v) + ';' for k,v in value.items()) + ' }'
    if isinstance(value, list): return '( ' + ', '.join(quote(v) for v in value) + (',' if value else '') + ' )'
    return json.dumps(str(value), ensure_ascii=False)

local = obj('localPackage', isa='XCLocalSwiftPackageReference', relativePath='.')
remote = obj('xlsxPackage', isa='XCRemoteSwiftPackageReference', repositoryURL='https://github.com/CoreOffice/CoreXLSX.git', requirement={'kind':'upToNextMinorVersion','minimumVersion':'0.14.1'})
groups = {}
for folder in ['App', 'Widgets', 'Shared/Activity', 'UITests', 'Tests/AppTests']:
    (root/folder).mkdir(parents=True,exist_ok=True)
    groups[folder] = obj('folder'+folder,isa='PBXFileSystemSynchronizedRootGroup',path=folder,sourceTree='<group>',explicitFileTypes={},explicitFolders=[])

targets = {}
for name, product, type_, folders in [
    ('CourseFlow','CourseFlow.app','com.apple.product-type.application',['App','Shared/Activity']),
    ('CourseFlowTrial','CourseFlowTrial.app','com.apple.product-type.application',['App','Shared/Activity']),
    ('CourseWidgets','CourseWidgets.appex','com.apple.product-type.app-extension',['Widgets','Shared/Activity']),
    ('CourseFlowUITests','CourseFlowUITests.xctest','com.apple.product-type.bundle.ui-testing',['UITests']),
    ('CourseFlowTests','CourseFlowTests.xctest','com.apple.product-type.bundle.unit-test',['Tests/AppTests'])]:
    filetype = 'wrapper.application' if name in ['CourseFlow','CourseFlowTrial'] else ('wrapper.app-extension' if name=='CourseWidgets' else 'wrapper.cfbundle')
    productRef = obj(name+'product',isa='PBXFileReference',explicitFileType=filetype,includeInIndex=0,path=product,sourceTree='BUILT_PRODUCTS_DIR')
    deps=[]; buildfiles=[]
    if name!='CourseFlowUITests':
        dep = obj(name+'core',isa='XCSwiftPackageProductDependency',package=local,productName='CourseKit'); deps.append(dep)
        buildfiles.append(obj(name+'corebuild',isa='PBXBuildFile',productRef=dep))
    if name in ['CourseFlow','CourseFlowTrial']:
        dep=obj(name+'xlsx',isa='XCSwiftPackageProductDependency',package=remote,productName='CoreXLSX');deps.append(dep)
        buildfiles.append(obj(name+'xlsxbuild',isa='PBXBuildFile',productRef=dep))
    phases=[obj(name+'sources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0),obj(name+'frameworks',isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=buildfiles,runOnlyForDeploymentPostprocessing=0),obj(name+'resources',isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
    configs=[]
    for configuration in ['Debug','Release']:
        settings={'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'com.courseflow.app'+('' if name=='CourseFlow' else ('.widgets' if name=='CourseWidgets' else ('.tests' if name=='CourseFlowTests' else '.uitests'))),'SWIFT_VERSION':'6.0','IPHONEOS_DEPLOYMENT_TARGET':'26.0','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SWIFT_EMIT_LOC_STRINGS':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks'],'GENERATE_INFOPLIST_FILE':'NO'}
        if name=='CourseFlow': settings.update({'INFOPLIST_FILE':'Config/App-Info.plist','CODE_SIGN_ENTITLEMENTS':'Config/CourseFlow.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'AccentColor','APS_ENVIRONMENT':'production' if configuration=='Release' else 'development'})
        elif name=='CourseFlowTrial': settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.courseflow.app.trial','INFOPLIST_FILE':'Config/Trial-Info.plist','CODE_SIGN_ENTITLEMENTS':'Config/CourseFlowTrial.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'AccentColor','COURSEFLOW_ICLOUD_ENABLED':'NO'})
        elif name=='CourseWidgets': settings.update({'INFOPLIST_FILE':'Config/Widgets-Info.plist','CODE_SIGN_ENTITLEMENTS':'Config/CourseWidgets.entitlements','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']})
        elif name=='CourseFlowUITests': settings.update({'GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'CourseFlow'})
        else: settings.update({'GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/CourseFlow.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CourseFlow','BUNDLE_LOADER':'$(TEST_HOST)'})
        if configuration=='Debug': settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG $(inherited)','ONLY_ACTIVE_ARCH':'YES'})
        config=obj(name+configuration,isa='XCBuildConfiguration',buildSettings=settings,name=configuration)
        configs.append(config)
    configlist=obj(name+'configs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
    targets[name]=obj(name,isa='PBXNativeTarget',buildConfigurationList=configlist,buildPhases=phases,buildRules=[],dependencies=[],fileSystemSynchronizedGroups=[groups[f] for f in folders],name=name,packageProductDependencies=deps,productName=name,productReference=productRef,productType=type_)

proxy=obj('extensionProxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=targets['CourseWidgets'],remoteInfo='CourseWidgets')
objects[targets['CourseFlow']]['dependencies']=[obj('extensionDependency',isa='PBXTargetDependency',target=targets['CourseWidgets'],targetProxy=proxy)]
embed=obj('embedextensionbuild',isa='PBXBuildFile',fileRef=uid('CourseWidgetsproduct'),settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
objects[targets['CourseFlow']]['buildPhases'].append(obj('embedExtensions',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embed],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0))
proxy=obj('testProxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=targets['CourseFlow'],remoteInfo='CourseFlow')
objects[targets['CourseFlowUITests']]['dependencies']=[obj('testDependency',isa='PBXTargetDependency',target=targets['CourseFlow'],targetProxy=proxy)]
objects[targets['CourseFlowTests']]['dependencies']=[obj('unitTestDependency',isa='PBXTargetDependency',target=targets['CourseFlow'],targetProxy=proxy)]
products=obj('products',isa='PBXGroup',children=[uid(n+'product') for n in targets],name='Products',sourceTree='<group>')
maingroup=obj('mainGroup',isa='PBXGroup',children=list(groups.values())+[products],sourceTree='<group>')
configRef=obj('localconfig',isa='PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Project.xcconfig',sourceTree='<group>')
objects[maingroup]['children'].append(configRef)
projectconfigs=[]
for config in ['Debug','Release']:
    projectconfigs.append(obj('project'+config,isa='XCBuildConfiguration',baseConfigurationReference=configRef,name=config,buildSettings={'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'YES','SWIFT_COMPILATION_MODE':'wholemodule' if config=='Release' else 'singlefile','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym' if config=='Release' else 'dwarf','ENABLE_TESTABILITY':'YES' if config=='Debug' else 'NO'}))
configlist=obj('projectconfigs',isa='XCConfigurationList',buildConfigurations=projectconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
obj('project',isa='PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastSwiftUpdateCheck':'2700','LastUpgradeCheck':'2700'},buildConfigurationList=configlist,compatibilityVersion='Xcode 16.0',developmentRegion='zh-Hans',hasScannedForEncodings=0,knownRegions=['zh-Hans','en','Base'],mainGroup=maingroup,preferredProjectObjectVersion=77,productRefGroup=products,projectDirPath='',projectRoot='',packageReferences=[local,remote],targets=list(targets.values()))
project=root/'CourseFlow.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+quote({'archiveVersion':1,'classes':{},'objectVersion':77,'objects':objects,'rootObject':uid('project')})+'\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def ref(name,buildable): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targets[name]}" BuildableName="{buildable}" BlueprintName="{name}" ReferencedContainer="container:CourseFlow.xcodeproj"/>'
(schemes/'CourseFlow.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('CourseFlow','CourseFlow.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('CourseFlowUITests','CourseFlowUITests.xctest')}</TestableReference><TestableReference skipped="NO">{ref('CourseFlowTests','CourseFlowTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('CourseFlow','CourseFlow.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('CourseFlow','CourseFlow.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(project)

(schemes/'CourseFlowTrial.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('CourseFlowTrial','CourseFlowTrial.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('CourseFlowTrial','CourseFlowTrial.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('CourseFlowTrial','CourseFlowTrial.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
