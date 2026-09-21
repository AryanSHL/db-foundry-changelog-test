--liquibase formatted sql

--changeset tarun.krishan:V0.04234.01:AMI-5682:dd labels:pre context:user-db
--comment: AMI-5682:dddd

update users set email = 'abc@test.com' where email = 'aaa@jjf.com';
