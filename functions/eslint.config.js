// @ts-check
import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';

/**
 * Lint for the Cloud Functions: the recommended rules, plus the few that have
 * caught real bugs in this codebase — a promise nobody awaited, a variable
 * nobody read.
 */
export default tseslint.config(
  { ignores: ['lib/**', 'node_modules/**', '*.js'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['src/**/*.ts', 'test/**/*.ts'],
    languageOptions: {
      globals: { ...globals.node },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // A floating promise in a callable is work the platform may kill
      // halfway; say \`void\` when that is really meant.
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', destructuredArrayIgnorePattern: '^_' },
      ],
      eqeqeq: ['error', 'always'],
      'no-console': 'error',
    },
  },
  {
    files: ['test/**/*.ts'],
    rules: {
      // Tests assert on shapes the types do not know; that is their job.
      '@typescript-eslint/no-non-null-assertion': 'off',
      'no-console': 'off',
    },
  },
);
