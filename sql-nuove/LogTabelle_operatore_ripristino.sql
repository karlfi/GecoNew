-- Ripristino di LogTabelle_operatore.sql: i trigger di storico tornano a scrivere SUSER_NAME() (definizioni in
-- produzione al 25/09/2026). La funzione dbo.AI_Operatore() si lascia: non da' fastidio.
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- CLIENTI
ALTER TRIGGER [dbo].[TR_INSUP_CLIENTI] 
   ON  dbo.CLIENTI
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'CLIENTI', SUSER_NAME(), CASE WHEN DEL.Idcliente IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idcliente
  from dbo.CLIENTI TAB
       inner join inserted INS ON INS.Idcliente = TAB.Idcliente 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idcliente = TAB.Idcliente) DEL
       cross apply (select *
                    from CLIENTI TAB2 
                    where TAB2.Idcliente = TAB.Idcliente
                    FOR XML RAW ('CLIENTI'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- GEO_COPERTURE
ALTER TRIGGER [dbo].[TR_INSUP_COPERTURE] 
   ON  [dbo].[GEO_COPERTURE]
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'GEO_COPERTURE', SUSER_NAME(), CASE WHEN DEL.IdCopertura IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.IdCopertura
  from dbo.GEO_COPERTURE TAB
       inner join inserted INS ON INS.IdCopertura = TAB.IdCopertura 
       outer apply (select * from deleted DEL2 WHERE DEL2.IdCopertura = TAB.IdCopertura) DEL
       cross apply (select *
                    from GEO_COPERTURE TAB2 
                    where TAB2.IdCopertura = TAB.IdCopertura
                    FOR XML RAW ('GEO_COPERTURE'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- MEZZI
ALTER TRIGGER [dbo].[TR_INSUP_MEZZI] 
   ON  dbo.MEZZI
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'MEZZI', SUSER_NAME(), CASE WHEN DEL.Idmezzo IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idmezzo
  from dbo.MEZZI TAB
       inner join inserted INS ON INS.Idmezzo = TAB.Idmezzo 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idmezzo = TAB.Idmezzo) DEL
       cross apply (select *
                    from MEZZI TAB2 
                    where TAB2.Idmezzo = TAB.Idmezzo
                    FOR XML RAW ('MEZZI'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- PRODOTTI
ALTER TRIGGER [dbo].[TR_INSUP_PRODOTTI] 
   ON  dbo.PRODOTTI
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'PRODOTTI', SUSER_NAME(), CASE WHEN DEL.Idprodotto IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idprodotto
  from dbo.PRODOTTI TAB
       inner join inserted INS ON INS.Idprodotto = TAB.Idprodotto 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idprodotto = TAB.Idprodotto) DEL
       cross apply (select *
                    from PRODOTTI TAB2 
                    where TAB2.Idprodotto = TAB.Idprodotto
                    FOR XML RAW ('PRODOTTI'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- SPED_AZIONI
ALTER TRIGGER [dbo].[TR_INSUP_SPED_AZIONI] 
   ON  dbo.SPED_AZIONI
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'SPED_AZIONI', SUSER_NAME(), CASE WHEN DEL.Idazione IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idazione
  from dbo.SPED_AZIONI TAB
       inner join inserted INS ON INS.Idazione = TAB.Idazione 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idazione = TAB.Idazione) DEL
       cross apply (select *
                    from SPED_AZIONI TAB2 
                    where TAB2.Idazione = TAB.Idazione
                    FOR XML RAW ('SPED_AZIONI'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- SPED_STATI
ALTER TRIGGER [dbo].[TR_INSUP_SPED_STATI] 
   ON  [dbo].[SPED_STATI]
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'SPED_STATI', SUSER_NAME(), CASE WHEN DEL.idstato IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idstato
  from dbo.SPED_STATI TAB
       inner join inserted INS ON INS.Idstato = TAB.Idstato 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idstato = TAB.Idstato) DEL
       cross apply (select *
                    from SPED_STATI TAB2 
                    where TAB2.Idstato = TAB.Idstato
                    FOR XML RAW ('SPED_STATO'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- SPED_WORKFLOW
ALTER TRIGGER [dbo].[TR_INSUP_SPED_WORKFLOW] 
   ON  [dbo].[SPED_WORKFLOW]
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'SPED_WORKFLOW', SUSER_NAME(), CASE WHEN DEL.Idworkflow IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idworkflow
  from dbo.SPED_WORKFLOW TAB
       inner join inserted INS ON INS.Idworkflow = TAB.Idworkflow 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idworkflow = TAB.Idworkflow) DEL
       cross apply (select *
                    from SPED_WORKFLOW TAB2 
                    where TAB2.Idworkflow = TAB.Idworkflow
                    FOR XML RAW ('SPED_WORKFLOW'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- UTENTI
ALTER TRIGGER [dbo].[TR_DEL_UTENTI] 
   ON  [dbo].[utenti]
   AFTER DELETE
AS 
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'UTENTI', SUSER_NAME(), 'DELETE', XMLDOC, DEL.Idutente
  from deleted DEL 
       cross apply (select *
                    from deleted TAB2 
                    where TAB2.Idutente = DEL.Idutente
                    FOR XML RAW ('utenti'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
--  EXECUTE [dbo].[uspLogError];
end catch  

END
GO

-- UTENTI
ALTER TRIGGER [dbo].[TR_INSUP_UTENTI] 
   ON  [dbo].UTENTI
   AFTER INSERT,UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'UTENTI', SUSER_NAME(), CASE WHEN DEL.Idutente IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.Idutente
  from dbo.utenti TAB
       inner join inserted INS ON INS.Idutente = TAB.Idutente 
       outer apply (select * from deleted DEL2 WHERE DEL2.Idutente = TAB.Idutente) DEL
       cross apply (select *
                    from utenti TAB2 
                    where TAB2.Idutente = TAB.Idutente
                    FOR XML RAW ('utente'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO

-- UTENTI_ATTIVITA
ALTER TRIGGER [dbo].[TR_UP_UTENTIATTIVITA] 
   ON  [dbo].[UTENTI_ATTIVITA]
   AFTER UPDATE
AS 
BEGIN

	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


begin try
  insert into [LogTabelle](Tabella,Operatore,TipoOperazione,Record, IdTabella)
  SELECT 'UTENTI_ATTIVITA', SUSER_NAME(), CASE WHEN DEL.IdAttivita IS NULL THEN 'INSERT' ELSE 'UPDATE' END, XMLDOC, TAB.IdAttivita
  from dbo.UTENTI_ATTIVITA TAB
       inner join inserted INS ON INS.IdAttivita = TAB.IdAttivita 
       outer apply (select * from deleted DEL2 WHERE DEL2.IdAttivita = TAB.IdAttivita) DEL
       cross apply (select *
                    from UTENTI_ATTIVITA TAB2 
                    where TAB2.IdAttivita = TAB.IdAttivita
                    FOR XML RAW ('UTENTI_ATTIVITA'), ELEMENTS, TYPE) AS RECXML(XMLDOC)
end try
begin catch
end catch  

END
GO
