-- Nuovo tipo di step: esecuzione di uno script Python (motore GecoMotore).
-- WF_TipoStep e' una lookup senza stored: si allinea come fa database.sql.
IF NOT EXISTS (SELECT 1 FROM dbo.WF_TipoStep WHERE Codice = 'ESEGUIPYTHON')
    INSERT INTO dbo.WF_TipoStep (Codice, Descrizione, SupportaSottopassi, Attivo)
    VALUES ('ESEGUIPYTHON', 'Esegue uno script Python (Script, Argomenti, directory, TimeoutSecondi)', 0, 1);
GO
