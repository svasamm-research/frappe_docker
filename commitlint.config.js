// Commitlint configuration — mirrors cafirm_override and Frappe convention.
// Docs: https://commitlint.js.org
//
// Commit format:  type(optional-scope): short subject
//
// Examples:
//   feat(cafirm): add uat apps config
//   fix(containerfile): pin frappe base image digest
//   chore: upgrade prettier to v3
//   ci: add semantic-commits job to lint workflow
//   docs: add branch naming strategy

module.exports = {
  parserPreset: "conventional-changelog-conventionalcommits",
  rules: {
    "subject-empty": [2, "never"],
    "type-case": [2, "always", "lower-case"],
    "type-empty": [2, "never"],
    "type-enum": [
      2,
      "always",
      [
        "build", // build system or external dependency changes
        "chore", // maintenance (no production code change)
        "ci", // CI/CD configuration changes
        "docs", // documentation only
        "feat", // new feature
        "fix", // bug fix
        "perf", // performance improvement
        "refactor", // code change that neither fixes a bug nor adds a feature
        "revert", // reverts a previous commit
        "style", // formatting, missing semicolons — no logic change
        "test", // adding or updating tests
        "deprecate", // marks something as deprecated
      ],
    ],
  },
};
