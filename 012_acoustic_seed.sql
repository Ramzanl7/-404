-- Optional illustrative 3D audio settings, after migration 008 and seed 005.
-- Unit positions are metres, in the same coordinate space as seats.
UPDATE cinema.halls
SET audio_enabled=true,
 speaker_layout='[{"id":"front-left","x":-5,"y":2.5,"z":0,"channel":"L"},{"id":"front-right","x":5,"y":2.5,"z":0,"channel":"R"},{"id":"rear-left","x":-4.5,"y":2.2,"z":18,"channel":"SL"},{"id":"rear-right","x":4.5,"y":2.2,"z":18,"channel":"SR"}]'::jsonb,
 audio_reference_distance_m=2.0,
 audio_rolloff_factor=1.0
WHERE id='22222222-2222-4222-8222-222222222201';
UPDATE cinema.seats
SET audio_gain_db=CASE WHEN row_number<=3 THEN 1.5 WHEN row_number>=9 THEN -2 ELSE 0 END,
    audio_occlusion=CASE WHEN row_number>=9 THEN 0.15 ELSE 0 END,
    audio_delay_ms=CASE WHEN row_number>=9 THEN 18 ELSE 0 END
WHERE hall_id='22222222-2222-4222-8222-222222222201';
