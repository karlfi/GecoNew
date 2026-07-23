-- =============================================================
-- Valorizza FILIALI.IdFiliale_HRSpeedy (id filiale nel gestionale HR Speedy)
-- per le filiali Speedy (IdAzienda = 2), da file SEDI.xlsx (luglio 2026).
-- Idempotente: si puo' rieseguire.
-- Note di mapping:
--   HR 1  "SEDE"    -> 1069 TOSC - CALENZANO - Direzionale (sede aziendale)
--   HR 4  "FI SUD"  -> 2    TOSC - FIRENZE (Bagno a Ripoli = Firenze Sud)
--   HR 12 "HUB"     -> 36   TOSC - HUB SPEEDY
-- Senza corrispondenza HR (restano NULL): EXT*, URP*, LINEA* (partner),
-- SARD - CAGLIARI (1068), SARD - SDA OLBIA (1288), Filiale Temporanea (1293),
-- TOSC - SDA Firenze (1268), TOSC - PRATO (33, chiusa).
-- =============================================================

UPDATE FILIALI SET IdFiliale_HRSpeedy = 1  WHERE IDFILIALE = 1069; -- SEDE -> TOSC - CALENZANO - Direzionale
UPDATE FILIALI SET IdFiliale_HRSpeedy = 3  WHERE IDFILIALE = 21;   -- FI STROZZI -> TOSC - FIRENZE STROZZI
UPDATE FILIALI SET IdFiliale_HRSpeedy = 4  WHERE IDFILIALE = 2;    -- FI SUD -> TOSC - FIRENZE
UPDATE FILIALI SET IdFiliale_HRSpeedy = 5  WHERE IDFILIALE = 29;   -- LIVORNO -> TOSC - LIVORNO
UPDATE FILIALI SET IdFiliale_HRSpeedy = 6  WHERE IDFILIALE = 34;   -- ELBA -> TOSC - ELBA
UPDATE FILIALI SET IdFiliale_HRSpeedy = 7  WHERE IDFILIALE = 31;   -- GROSSETO -> TOSC - GROSSETO
UPDATE FILIALI SET IdFiliale_HRSpeedy = 8  WHERE IDFILIALE = 30;   -- SIENA -> TOSC - SIENA
UPDATE FILIALI SET IdFiliale_HRSpeedy = 9  WHERE IDFILIALE = 32;   -- EMPOLI -> TOSC - EMPOLI
UPDATE FILIALI SET IdFiliale_HRSpeedy = 10 WHERE IDFILIALE = 42;   -- PISTOIA -> TOSC - PISTOIA
UPDATE FILIALI SET IdFiliale_HRSpeedy = 11 WHERE IDFILIALE = 1065; -- OLBIA -> SARD - OLBIA
UPDATE FILIALI SET IdFiliale_HRSpeedy = 12 WHERE IDFILIALE = 36;   -- HUB -> TOSC - HUB SPEEDY
UPDATE FILIALI SET IdFiliale_HRSpeedy = 13 WHERE IDFILIALE = 1232; -- HUB POPUP -> TOSC - HUB POPUP
UPDATE FILIALI SET IdFiliale_HRSpeedy = 14 WHERE IDFILIALE = 37;   -- MASSA -> TOSC - SPEZIA/MASSA
UPDATE FILIALI SET IdFiliale_HRSpeedy = 15 WHERE IDFILIALE = 38;   -- LUCCA -> TOSC - LUCCA
UPDATE FILIALI SET IdFiliale_HRSpeedy = 17 WHERE IDFILIALE = 1196; -- ORISTANO -> SARD - ORISTANO
UPDATE FILIALI SET IdFiliale_HRSpeedy = 18 WHERE IDFILIALE = 1064; -- SASSARI -> SARD - SASSARI
UPDATE FILIALI SET IdFiliale_HRSpeedy = 19 WHERE IDFILIALE = 1063; -- NUORO -> SARD - NUORO
UPDATE FILIALI SET IdFiliale_HRSpeedy = 21 WHERE IDFILIALE = 1289; -- SDA CAGLIARI -> SARD - SDA CAGLIARI
UPDATE FILIALI SET IdFiliale_HRSpeedy = 22 WHERE IDFILIALE = 1248; -- PISA -> TOSC - Pisa
UPDATE FILIALI SET IdFiliale_HRSpeedy = 23 WHERE IDFILIALE = 1247; -- TORTOLI -> SARD - TORTOLI
UPDATE FILIALI SET IdFiliale_HRSpeedy = 24 WHERE IDFILIALE = 1292; -- SDA SASSARI -> SARD - SDA SASSARI
