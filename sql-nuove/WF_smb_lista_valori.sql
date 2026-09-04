-- Credenziali della condivisione di rete usata dai workflow dello schedulatore:
-- il motore (servizio) apre la sessione SMB verso SERVER con USER e PASS.
-- Stessa forma di SMTP_SERVER; USER e PASS si compilano dalla pagina Lista Valori.
-- Altri server: Lista = 'SMB_SERVER_2', 'SMB_SERVER_3' ...
IF NOT EXISTS (SELECT 1 FROM dbo.LISTA_VALORI WHERE Lista = 'SMB_SERVER')
BEGIN
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'SMB_SERVER', @Valore = 'SERVER', @Codice = '192.168.0.252', @Ordine = 1;
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'SMB_SERVER', @Valore = 'USER',   @Codice = '', @Ordine = 2;
    EXEC dbo.AI_LISTA_VALORI_Save @Lista = 'SMB_SERVER', @Valore = 'PASS',   @Codice = '', @Ordine = 3;
END
GO
