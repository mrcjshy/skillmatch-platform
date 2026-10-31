import type { E2EConfig } from 'e2e';
import { mobile } from '@e2e-dev/mobile';

export default {
  // Replace com.android.settings with your app's package name.
  targets: [{ name: 'android', engine: mobile({ platform: 'android' }), app: { bundleId: 'com.android.settings' } }],
  workers: 1,
} satisfies E2EConfig;
