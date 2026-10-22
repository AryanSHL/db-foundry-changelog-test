# db-foundry-changelog-test

Test changelog repo for DB Foundry. Its `dbs/` tree mirrors the layout of
`SHL-India/AM-db-migration-service`, so DB Foundry's generated PRs can be
checked against the real format. See `CLAUDE.md` for the full layout.

```
dbs/
├── dev|qa|stg|uat/
│   ├── sql/<db>/        changelog-master.xml + changeset/V<ver>_<JIRA>_<desc>.sql
│   └── MongoDB/<db>/    changelog-master.xml + changeset/V<ver>_<JIRA>_<desc>.yml
├── stg-rollback|uat-rollback/       same layout, rollback changesets
└── prod/
    ├── AU|EU|US|CH/                 same layout per region
    └── AU-rollback|EU-rollback|US-rollback|CH-rollback/
```

- Never edit `changelog-master.xml`; Liquibase picks up new files in `changeset/`.
- `MongoDB` is capitalised; `sql` is lowercase.
- Prod rollbacks live in `prod/<REGION>-rollback`, not `prod-rollback/`.
- Every DB has a `V0.0000_test_script` placeholder so its folder exists in git.
