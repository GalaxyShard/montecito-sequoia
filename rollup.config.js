import { nodeResolve } from '@rollup/plugin-node-resolve';

export default {
  input: 'editor/inject/editor.js',
  output: {
    dir: 'zig-out',
    format: 'cjs'
  },
  plugins: [nodeResolve()]
};
