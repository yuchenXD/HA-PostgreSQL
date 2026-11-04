CREATE TABLE IF NOT EXISTS public.pitr_backup_test (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    marker text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO public.pitr_backup_test (marker)
VALUES ('pitr_base_backup_test_20261022')
ON CONFLICT (marker) DO NOTHING;

SELECT id,
       marker,
       created_at
FROM public.pitr_backup_test
ORDER BY id;
