
// Match native compilation and packaging to Flutter's selected architecture.
import { hvigor, HvigorPlugin } from '@ohos/hvigor';
import { hapTasks, OhosHapContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

const nativeAbiPlugin: HvigorPlugin = {
    pluginId: 'venerax-native-abi',
    apply(node) {
        node.afterNodeEvaluate(() => {
            const mapping: Record<string, string> = {
                'ohos-arm64': 'arm64-v8a', 'ohos-x64': 'x86_64',
            };
            const platforms = hvigor.getParameter().getExtParam('TARGET_PLATFORM') ?? 'ohos-arm64,ohos-x64';
            const abis = platforms.split(',').map(platform => {
                const abi = mapping[platform];
                if (!abi) throw new Error(`Unsupported HarmonyOS platform: ${platform}`);
                return abi;
            });
            const context = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
            const profile = context.getBuildProfileOpt();
            profile.buildOption ??= {};
            profile.buildOption.externalNativeOptions = {
                ...profile.buildOption.externalNativeOptions, abiFilters: abis,
            };
            profile.buildOption.nativeLib ??= {};
            profile.buildOption.nativeLib.filter ??= {};
            profile.buildOption.nativeLib.filter.excludes = [
                ...(profile.buildOption.nativeLib.filter.excludes ?? []),
                ...Object.values(mapping).filter(abi => !abis.includes(abi)).map(abi => `${abi}/**`),
            ];
            context.setBuildProfileOpt(profile);
        });
    },
};

export default {
    system: hapTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins: [nativeAbiPlugin]
}
