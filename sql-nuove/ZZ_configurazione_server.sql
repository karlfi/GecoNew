-- =============================================================
-- Configurazione del SERVER di produzione (non e' codice dell'applicazione,
-- ma senza queste impostazioni le stored legacy si comportano diversamente)
-- =============================================================

-- LINGUA DEL LOGIN
-- Il vecchio server (SERVERDB) lavorava in Italiano, quindi con formato data
-- gg/mm/aaaa; il nuovo (BLUE) e' stato installato in us_english (mm/gg/aaaa).
--
-- Molte stored legacy costruiscono le date come testo italiano, ad esempio:
--     convert(varchar(10), sd.data, 103) + ' ' + left(convert(varchar(8), sd.data, 114), 8)
-- e poi quel testo torna a essere una data per via delle UNION. Con il formato
-- americano ogni giorno del mese superiore al 12 va fuori intervallo e la query
-- fallisce ("conversione di varchar in datetime ... valore fuori intervallo").
-- L'errore sembra intermittente perche' dipende dal giorno dei dati letti.
--
-- Ricercabarcode era una di queste: allineando la lingua torna a funzionare
-- senza toccare il codice legacy.
ALTER LOGIN twebaccount WITH DEFAULT_LANGUAGE = Italiano;
GO

-- Verifica (da eseguire su una connessione NUOVA: quelle aperte tengono la
-- lingua con cui sono nate, quindi dopo la modifica va riavviata l'applicazione)
SELECT @@LANGUAGE AS Lingua,
       (SELECT dateformat FROM sys.syslanguages WHERE name = @@LANGUAGE) AS FormatoData;
GO

-- DA VALUTARE, non ancora fatto:
--   - il login "sa" e' rimasto us_english: job, manutenzioni e query eseguite
--     con quel login possono incontrare lo stesso errore;
--   - anche la lingua predefinita dell'istanza e' us_english, quindi i login
--     creati in futuro nasceranno con il formato americano.
-- Per allinearli:
--   ALTER LOGIN sa WITH DEFAULT_LANGUAGE = Italiano;
--   EXEC sp_configure 'default language', 6; RECONFIGURE;   -- 6 = Italiano
