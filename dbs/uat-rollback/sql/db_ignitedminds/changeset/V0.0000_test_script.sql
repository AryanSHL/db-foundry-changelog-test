--liquibase formatted sql
--changeset tarun.krishan:V0.0000:JIRA-0000:First_Script_For_Testing labels:post context:db_ignitedminds

--comment: JIRA-0000:First Script For Testing

SELECT COUNT(*) FROM information_schema.tables;
