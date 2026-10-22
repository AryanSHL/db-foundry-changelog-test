--liquibase formatted sql

--changeset aryan.jaiswal:V0.01.01:AMC-439:cvbnm-rollback labels:pre context:db_ignitedminds
--comment: AMC-439:fghjk - Rollback

SELECT COUNT(*) FROM tbl_modules;
