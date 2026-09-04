-- =============================================================
-- UTENTI_AttivitaMancanti recuperava le giornate mancanti ai soli driver,
-- mentre UTENTI_CreaAttivita le crea anche agli interni: nei giorni in cui la
-- generatrice non e' passata, gli interni restavano senza riga e sparivano
-- dalla pagina Attivita Dipendenti. Le due condizioni ora coincidono.
-- =============================================================

-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[UTENTI_AttivitaMancanti]
	-- Add the parameters for the stored procedure here
	@idutente int=null
	,@Startingdate date =null
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
	set @Startingdate=ISNULL(@Startingdate,'241101')

	DECLARE @StartDate DATE 
	DECLARE @EndDate DATE 
	--crea una temp con l'elenco di tutti i giorni
	set @StartDate='241101'
	set @EndDate=GETDATE();
	WITH DateRange AS
	(
		SELECT @StartDate AS DateValue
		UNION ALL
		SELECT DATEADD(DAY, 1, DateValue)
		FROM DateRange
		WHERE DATEADD(DAY, 1, DateValue) <= @EndDate
	)
	SELECT DateValue
	into #tmp
	FROM DateRange
	OPTION (MAXRECURSION 0);

		insert into utenti_Attivita (idutente,idfiliale,data,codPresenza,idMezzo
			,parami01,parami02,parami03,parami04,parami05,parami06,parami07,parami08,parami09,parami10
			,parami11,parami12,parami13,parami14,parami15,parami16,parami17,parami18,parami19,parami20
			,ParamB02,ParamB03,ParamB04,ParamB09,ParamB10,ParamB11
			,partime)
		select u.IdUtente,u.IdFiliale,yy.DateValue
			,case when u.idruolo=40 then 'NLV' else 'PRE' end
			,u.idmezzo_default
		,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
		,0,0,0,0,0,0
		,u.Partime


	from (
		select u.IdUtente,xx.DateValue from #tmp xx
		cross join UTENTI u 
		inner join FILIALI f on f.IDFILIALE=u.IdFiliale and f.IdAzienda=2
		where 1=1
			and ISNULL(u.datafine,getdate())>'241101'
			-- stessa condizione di UTENTI_CreaAttivita, che crea le righe del giorno:
			-- i driver piu' chiunque abbia un codice fiscale, cioe' gli interni.
			-- Prima qui c'erano i soli driver, quindi quando la generatrice
			-- giornaliera saltava un giorno (e' successo il 22 e 23 agosto) agli
			-- interni la riga non veniva piu' recuperata da nessuno.
			and (u.IdRuolo in (40,41,42) or len(isnull(u.CodiceFiscale,'')) > 0)
		) yy
		left join UTENTI u on u.IdUtente=yy.idutente
		left join UTENTI_ATTIVITA ua on ua.idUtente=yy.idutente and ua.data=yy.DateValue
		where 1=1
			and ua.idAttivita is null
			and yy.DateValue>=u.DataInizio
			and yy.DateValue>=@Startingdate
			and yy.DateValue<ISNULL(u.datafine,'20291231')
	order by 1,2
END

GO
