<?php
    $RETURN_METHOD = 'RETURN'; /* RETURN or OUTVAR */
    require __DIR__ . '/../_scripts/macros.php';
?>
CREATE OR REPLACE FUNCTION tm_cz.i2b2_move_analysis_to_prod_new(
    i_etl_id     bigint DEFAULT -1,
    currentJobID bigint DEFAULT null
)
RETURNS bigint AS $body$
DECLARE
    -- create indexes using parallele 8  -zhanh101 5/10/2013 use ~20-30% original time
    <?php standard_vars() ?>

    v_etl_id                 bigint;
    v_bio_assay_analysis_id  bigint;
    v_data_type              varchar(50);
    v_sqlText                varchar(2000);
    v_count                  integer;
    v_GWAS_staged            integer;
    v_EQTL_staged            integer;
    v_index_name             text;
    v_result                 bigint;

    stage_curs               refcursor;
    stage_rec                record;
    stage_table_name_rec     record;
BEGIN

    <?php func_start('I2B2_MOVE_ANALYSIS_TO_PROD_NEW') ?>

    --    set variables if staged data contains GWAS and/or EQTL data
    v_GWAS_staged := 0;
    v_EQTL_staged := 0;

    OPEN stage_curs SCROLL FOR
            SELECT
                baa.bio_assay_analysis_id,
                lz.etl_id,
                lz.study_id,
                CASE
                    WHEN lz.data_type in ('GWAS', 'Metabolic GWAS')
                    THEN 'GWAS'
                    ELSE lz.data_type
                END AS data_type,
                lz.data_type AS orig_data_type,
                lz.analysis_name
            FROM
                tm_lz.lz_src_analysis_metadata lz,
                biomart.bio_assay_analysis baa
            WHERE
                lz.status = 'STAGED'
                AND lz.study_id = baa.etl_id
                AND lz.etl_id = baa.etl_id_source
                AND CASE
                        WHEN i_etl_id = - 1 THEN 1
                        WHEN lz.etl_id = i_etl_id THEN 1
                        ELSE 0
                    END = 1;

    v_count := 0;
    LOOP
        FETCH stage_curs INTO stage_rec;
        EXIT WHEN NOT FOUND;

        v_count := v_count + 1;

        IF stage_rec.data_type = 'GWAS' THEN
            v_GWAS_staged := 1;
        END IF;
        IF stage_rec.data_type = 'EQTL' THEN
            v_EQTL_staged := 1;
        END IF;
    END LOOP;
    PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
            'Iterated staged metatdata. Found GWAS: ' || v_GWAS_staged::text ||
            ', found EQTL: ' || v_EQTL_staged::text, 0, v_count, 'Done');
    stepCt := stepCt + 1;

    IF v_count = 0 THEN
        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'No staged data - terminating normally', 0, stepCt, 'Done');
        PERFORM tm_cz.cz_end_audit(jobId, 'Sucess');
        RETURN 0;
    END IF;

    --    drop indexes if loading GWAS data
    IF v_GWAS_staged = 1 THEN
        SELECT T.conname
        INTO v_index_name
        FROM
            pg_class C
            INNER JOIN pg_namespace N ON ( N.OID = C.relnamespace ) -- get index's tablespace
            INNER JOIN pg_constraint T ON ( T.conindid = C.OID ) -- get constraint associated with index
            INNER JOIN pg_class C2 ON ( C2.OID = T.conrelid ) -- get info about constrained table
        WHERE
            C.relkind = 'i' -- restrict to indexes
            AND N.nspname = 'biomart'
            AND T.contype = 'p' -- primary key constraint
            AND C2.relname = 'bio_assay_analysis_gwas';

        IF FOUND THEN
            EXECUTE('ALTER TABLE biomart.bio_assay_analysis_gwas DROP CONSTRAINT ' ||
                    quote_ident(v_index_name));
        END IF;

        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Drop primary key on biomart.bio_assay_analysis_gwas', 0, stepCt, 'Done');
        stepCt := stepCt + 1;

        DROP INDEX IF EXISTS biomart.bio_assay_analysis_gwas_idx2;
        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Drop index biomart.bio_assay_analysis_gwas_idx2', 0, stepCt, 'Done');
        stepCt := stepCt + 1;
    END IF;

    --    delete any existing data in bio_assay_analysis_gwas and bio_assay_analysis_eqtl
    IF v_GWAS_staged = 1 THEN
        <?php step_begin() ?>
        DELETE
        FROM
            biomart.bio_assay_analysis_gwas g
        WHERE
            g.bio_assay_analysis_id IN (
                SELECT
                    x.bio_assay_analysis_id
                FROM
                    tm_lz.lz_src_analysis_metadata t,
                    biomart.bio_assay_analysis x
                WHERE
                    t.status = 'STAGED'
                    AND t.data_type IN ( 'GWAS', 'Metabolic GWAS' )
                    AND t.study_id = x.etl_id
                    AND t.etl_id = x.etl_id_source
                    AND CASE
                        WHEN i_etl_id = - 1 THEN 1
                        WHEN t.etl_id = i_etl_id THEN 1
                        ELSE 0
                    END = 1 );
        <?php step_end('Delete exising data for staged analyses from BIOMART.BIO_ASSAY_ANALYSIS_GWAS') ?>
    END IF;

    IF v_EQTL_staged = 1 THEN
        <?php step_begin() ?>
        DELETE
        FROM
            biomart.bio_assay_analysis_eqtl g
        WHERE
            g.bio_assay_analysis_id IN (
                SELECT
                    x.bio_assay_analysis_id
                FROM
                    tm_lz.lz_src_analysis_metadata t,
                    biomart.bio_assay_analysis x
                WHERE
                    t.status = 'STAGED'
                    AND t.data_type = 'EQTL'
                    AND t.study_id = x.etl_id
                    AND t.etl_id = x.etl_id_source
                    AND CASE
                        WHEN i_etl_id = - 1 THEN 1
                        WHEN t.etl_id = i_etl_id THEN 1
                        ELSE 0
                    END = 1 );
        <?php step_end('Delete exising data for staged analyses from BIOMART.BIO_ASSAY_ANALYSIS_EQTL') ?>
    END IF;

    IF v_GWAS_staged = 1 THEN
        DROP INDEX IF EXISTS biomart.bio_assay_analysis_gwas_idx1;

        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Drop index biomart.bio_assay_analysis_gwas_idx1', 0, stepCt, 'Done');
        stepCt := stepCt + 1;
    END IF;

    MOVE BACKWARD ALL FROM stage_curs;
    LOOP
        FETCH stage_curs INTO stage_rec;
        EXIT WHEN NOT FOUND;

        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Loading ' || stage_rec.study_id || ' ' || stage_rec.orig_data_type || ' ' ||
                stage_rec.analysis_name || ' ' || stage_rec.bio_assay_analysis_id, 0, stepCt, 'Starting');
        stepCt := stepCt + 1;

        v_etl_id                := stage_rec.etl_id;
        v_bio_assay_analysis_id := stage_rec.bio_assay_analysis_id;
        v_data_type             := stage_rec.data_type;

        IF v_data_type = 'EQTL' THEN
            <?php step_begin() ?>
            INSERT INTO biomart.bio_assay_analysis_eqtl (
                bio_asy_analysis_eqtl_id,
                bio_assay_analysis_id,
                rs_id,
                gene,
                p_value,
                p_value_char,
                cis_trans,
                distance_from_gene,
                etl_id,
                ext_data,
                log_p_value )
            SELECT
                bio_asy_analysis_eqtl_id,
                bio_assay_analysis_id,
                rs_id,
                gene,
                p_value_char::double precision,
                p_value_char,
                cis_trans,
                distance_from_gene,
                etl_id,
                ext_data,
                LOG ( 10::numeric, p_value_char::numeric )::double precision * - 1
            FROM
                biomart_stage.bio_assay_analysis_eqtl
            WHERE
                bio_assay_analysis_id = v_bio_assay_analysis_id;

            <?php step_end('Insert data for analysis from BIOMART_STAGE.BIO_ASSAY_ANALYSIS_EQTL') ?>

        ELSIF v_data_type = 'GWAS' THEN
            <?php step_begin() ?>
            INSERT INTO biomart.bio_assay_analysis_gwas (
                bio_asy_analysis_gwas_id,
                bio_assay_analysis_id,
                rs_id,
                p_value,
                p_value_char,
                etl_id,
                ext_data,
                log_p_value )
            SELECT
                bio_asy_analysis_gwas_id,
                bio_assay_analysis_id,
                rs_id,
                p_value_char::double precision,
                p_value_char,
                etl_id,
                ext_data,
                LOG ( 10::numeric, p_value_char::numeric )::double precision * - 1
            FROM
                biomart_stage.bio_assay_analysis_gwas
            WHERE
                bio_assay_analysis_id = v_bio_assay_analysis_id;

            <?php step_end('Insert data for analysis from BIOMART_STAGE.BIO_ASSAY_ANALYSIS_GWAS') ?>
        ELSE
            PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                    'Skipping unrecognized analysys: ' || v_data_type, 0, stepCt, 'Done');
            stepCt := stepCt + 1;
        END IF;

        IF i_etl_id > -1 THEN
            v_sqlText := 'DELETE FROM biomart_stage.bio_assay_analysis_' || v_data_type ||
                         ' WHERE bio_assay_analysis_id = ' || to_char(v_bio_assay_analysis_id);

            <?php step_begin() ?>
            EXECUTE(v_sqlText);
            <?php step_end("'Delete data for analysis from BIOMART_STAGE.BIO_ASSAY_ANALYSIS_' || v_data_type") ?>
        END IF;

        <?php step_begin() ?>
        UPDATE tm_lz.lz_src_analysis_metadata
        SET
            status = 'PRODUCTION'
        WHERE
            etl_id = v_etl_id;
        <?php step_end('Set status to PRODUCTION in tm_lz.lz_src_analysis_metadata') ?>
    END LOOP;

    IF i_etl_id = -1 THEN
        FOR stage_table_name_rec IN
                    SELECT
                        relname AS table_name
                    FROM
                        pg_class C
                    INNER
                        JOIN pg_namespace N ON ( N.OID = C.relnamespace )
                    WHERE
                        relkind = 'r'
                        AND N.nspname = 'biomart_stage'
                        AND relname LIKE 'bio_assay_analysis%' LOOP

            v_sqlText := 'TRUNCATE TABLE biomart_stage.' || stage_table_name_rec.table_name;
            <?php step_begin() ?>
            EXECUTE(v_sqlText);
            <?php step_end("'Truncated biomart_stage.' || stage_table_name_rec.table_name") ?>
        END LOOP;
    END IF;

    --    recreate GWAS indexes if needed
    IF v_GWAS_staged = 1 THEN
        CREATE INDEX bio_assay_analysis_gwas_idx1 ON biomart.bio_assay_analysis_gwas(bio_assay_analysis_id) TABLESPACE indx;
        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Created index bio_assay_analysis_gwas_idx1', 0, stepCt, 'Done');
        stepCt := stepCt + 1;

        CREATE INDEX bio_assay_analysis_gwas_idx2 ON biomart.bio_assay_analysis_gwas(rs_id) TABLESPACE indx;
        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Created index bio_assay_analysis_gwas_idx2', 0, stepCt, 'Done');
        stepCt := stepCt + 1;

        ALTER TABLE biomart.bio_assay_analysis_gwas
                ADD CONSTRAINT bio_assay_analysis_gwas_pkey PRIMARY KEY(bio_asy_analysis_gwas_id)
                USING INDEX TABLESPACE indx;
        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName,
                'Created primary key bio_assay_analysis_gwas_pkey', 0, stepCt, 'Done');
        stepCt := stepCt + 1;

        SELECT tm_cz.i2b2_load_eqtl_top50(jobID) INTO v_result;
        IF v_result < 0 THEN
            PERFORM tm_cz.cz_error_handler(jobID, procedureName, '', 'Call to i2b2_load_eqtl_top50 failed');
            PERFORM tm_cz.cz_end_audit (jobID, 'FAIL');
            RETURN -16;
        END IF;

        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName, 'Created top 50 EQTL', 0, stepCt, 'Done');
        stepCt := stepCt + 1;

        SELECT tm_cz.i2b2_load_gwas_top50()  INTO v_result;
        IF v_result < 0 THEN
            PERFORM tm_cz.cz_error_handler(jobID, procedureName, '', 'Call to i2b2_load_gwas_top50 failed');
            PERFORM tm_cz.cz_end_audit (jobID, 'FAIL');
            RETURN -16;
        END IF;

        PERFORM tm_cz.cz_write_audit(jobId, databaseName, procedureName, 'Created top 50 GWAS', 0, stepCt, 'Done');
        stepCt := stepCt + 1;
    END IF;

    --Insert data_count to bio_assay_analysis table. added by Haiyan Zhang 01/22/2013
    MOVE BACKWARD ALL FROM stage_curs;
    LOOP
        FETCH stage_curs INTO stage_rec;
        EXIT WHEN NOT FOUND;

        v_bio_assay_analysis_id := stage_rec.bio_assay_analysis_id;
        v_data_type             := stage_rec.data_type;
        IF v_data_type = 'EQTL' THEN
            <?php step_begin() ?>
            UPDATE biomart.bio_assay_analysis ANAL
            SET
                data_count = COUNTS.count
            FROM (
                    SELECT
                        E.bio_assay_analysis_id,
                        COUNT ( * ) AS COUNT
                    FROM
                        biomart.bio_assay_analysis_eqtl E
                    GROUP BY
                        E.bio_assay_analysis_id )
                COUNTS
            WHERE
                ANAL.bio_assay_analysis_id = v_bio_assay_analysis_id
                AND COUNTS.bio_assay_analysis_id = ANAL.bio_assay_analysis_id;
            <?php step_end("'Update data_count for EQTL analysis ' || v_bio_assay_analysis_id") ?>

        ELSE
            <?php step_begin() ?>
            UPDATE biomart.bio_assay_analysis ANAL
            SET
                data_count = COUNTS.count
            FROM (
                    SELECT
                        G.bio_assay_analysis_id,
                        COUNT ( * ) AS COUNT
                    FROM
                        biomart.bio_assay_analysis_gwas G
                    GROUP BY
                        G.bio_assay_analysis_id )
                COUNTS
            WHERE
                ANAL.bio_assay_analysis_id = v_bio_assay_analysis_id
                AND COUNTS.bio_assay_analysis_id = ANAL.bio_assay_analysis_id;
            <?php step_end("'Update data_count for GWAS analysis ' || v_bio_assay_analysis_id") ?>
        END IF;
    END LOOP;
    ---end added by Haiyan Zhang

    <?php func_end() ?>
END;
$body$
LANGUAGE PLPGSQL;
<?php // vim: ft=plsql ts=4 sts=4 sw=4 et:
?>