-- =============================================================
-- AUTO_Sched_ORE_01 - Schedulazione notturna (ore 01)
--
-- Su questo database mancano oggetti che la procedura richiamava, quindi
-- andava in errore. E' stato commentato le chiamate a TOPPA_aggiorna_idmesso,
-- CONSIP_GeneraPickup e TMP_recupera_consegne.
-- Il resto della procedura e' invariato e continua a funzionare.
--
-- Per riattivare: ricreare prima gli oggetti mancanti, poi togliere il
-- commento. Il file e' la definizione completa: si puo' rieseguire com'e'.
-- =============================================================



-- AUTO_Sched_ORE_01: commentate INSERT di archiviazione E la DELETE che la segue.
-- Vanno insieme: lasciare la DELETE senza l'INSERT cancellerebbe le righe
-- senza averle archiviate. Restano i REBUILD degli indici.
-- Nota: il blocco era gia' inerte all'origine, manca '@maxid =' alla riga
-- 'select MAX(id) from Speedy.dbo.PALM_RAW', quindi @maxid resta NULL.
-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[AUTO_Sched_ORE_01]
	-- Add the parameters for the stored procedure here

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	-- DISATTIVATO (agosto 2026): TOPPA_aggiorna_idmesso non esiste piu' su questo database.
	-- (allineava l'IdMesso sulle spedizioni)
	--exec TOPPA_aggiorna_idmesso

	--rendiconto le AG ADE non trovate
	update SPED_ATTIVITA set stato='X9' 
		where stato='X7' and datastato<dateadd(d,-4,getdate())
	update SPED_SPED2DISTINTE set Stato_Fine ='X9'
		from SPED_ATTIVITA sa
		inner join SPED_SPED2DISTINTE sd on sd.IdSpedizione=Sa.IdSpedizione and sd.Stato_Fine ='X7'
	where sa.Stato='X9' and sd.Stato_Fine ='X7'


	delete from Speedy.dbo.LOGTabelle where Data<dateadd(d,-60,GETDATE())
	
	-- pickup CONSIP
	-- DISATTIVATO (agosto 2026): CONSIP_GeneraPickup non esiste piu' su questo database.
	-- (generava i pickup CONSIP)
	--exec CONSIP_GeneraPickup

	--importa fornitori
	insert into FORNITORI (CPCODICE,Fornitore)
	select distinct x.cpcodice,trim(x.cpdenomi + ' ' + CPCOGNOM + ' ' + CP__NOME )
	from Speedy.dbo.FATEL_LEALIFAT_MAST x
	left join FORNITORI f on f.CPCODICE=x.CPCODICE
	where 1=1
		and f.CPCODICE is null
		and isnull(trim(x.cpdenomi + ' ' + CPCOGNOM + ' ' + CP__NOME ),'')<>''

	--tolgo i fornitori doppi
	delete from FORNITORI
	from FORNITORI f
	left join (	select MIN(id) id,cpcodice from FORNITORI 	group by cpcodice ) x on x.id=f.ID
	where x.id is null


    -- Insert statements for procedure here
	-- DISATTIVATO (agosto 2026): TMP_recupera_consegne non esiste piu' su questo database.
	-- (recuperava consegne rimaste indietro)
	--exec TMP_recupera_consegne
	exec UTENTI_CreaAttivita
	exec TOPPA_InserisciNomeTerzi

	--aggiorna le giacenza degli AG sulla base dei cambi sulla tabella GEO_Coperture
	exec [SPED_AggiornaGiacenza]

	delete from FILE_LOAD where dataload<dateadd(d,-30,getdate())
	delete from LOG_Exec where datainserimento<dateadd(d,-180,getdate())
	delete from speedy.dbo.PALM_RAW_SCARTATI where datainserimento<dateadd(d,-60,getdate())

	--svuoto i giri non ultimati dal palmare e gli tolgo l'utente in modo che non appaiano in automatico il giorno dopo
	update PALM_ATTIVITA set driverassegnato='' where tipoEventoCodice='R_007' and isnull(DriverAssegnato,'')<>'' and stato='01'
	
	--Aggiorna gli esiti delle raccomandate 140 ADER4 sulla cartella
	UPDATE SPED_ATTIVITA
	SET esitoracc=sracc.stato,dataesitoracc=sracc.datastato
	FROM  SPED_ATTIVITA 
	INNER JOIN  SPED_ATTIVITA AS sracc 
		ON sracc.Riferimento = SPED_ATTIVITA.IdSpedizione 
		AND sracc.TipoRiferimento = 0 
		AND sracc.IdProdotto = 6
	WHERE (1 = 1) 
	AND (sracc.Stato IN ('11', '90', '91', '95', '99', '9G')) 
	AND (SPED_ATTIVITA.EsitoRacc IS NULL) 
	AND (SPED_ATTIVITA.IdCliente = 5322)
	and sracc.DataFine is not null





	--invio promemoria mezzi
	if datepart(dw,getdate())=2
		exec PROMEMORIA_InvioMailMezzi




	--aggiorna la tabella dei costi dei mezzi dal db speedy
	--insert into costi (IDspeedy,IdAzienda,seriale,PrezzoUnitario,Totale,iva,tipo,Quantita,ndoc,DataDoc,DataRit,Fornitore,Targa,Noleggio)
	--select x.id,2 ,x.seriale,x.PrezzoUnitario,x.Totale,x.iva,x.tipo,x.Quantita,x.ndoc,x.DataDoc,x.DataRit,x.Fornitore,x.Targa,x.Noleggio 
	--from speedy.dbo.ops_costi x
	--left join costi c on c.IDspeedy =x.id
	--where c.IdCosti is null
	exec COSTI_Importazione

	--attribuisci costi-targhe
	exec COSTI_attribuisci_targhe

	update costi set cdc=f.CodZUK + mt.codTipoZuk,TotaleFinale=totale
	from COSTI c
	inner join MEZZI m on m.targa=c.Targa
			inner join MEZZI_TIPI mt on mt.codTipoMezzo=m.codTipoMezzo
			inner join FILIALI f on f.IDFILIALE=m.idFiliale
			inner join COSTI_TipoAnalitica ct on ct.Attivita=mt.codTipoZuk
	where cdc is null and c.targa is not null

	--aggiorno i dati del codice fiscale del fornitore costi
	update costi set CpCodice=x.CPCODICE
	from costi c
	inner join Speedy.[dbo].[FATEL_LEALIFAT_MAST] x on x.FASERIAL=c.Seriale
	where c.CpCodice is null
	




	--aggiorna i dati dello scontrino 
	--per poter gestire i casi dei postinio che si prendono il materiale la sera
	--e poi consegnano nei giorni successivi
	exec PALM_AggiornaScontrino


	--toppone per COnSIP, aggiorna i lotti inseriti manualmente 
			update SPED_LOTTI set IdCrmAzione=13  
				where IdCliente=5318 
				and IdCrmAzione is null 
				and Lotto like '%CRC_CSO%'

			update SPED_LOTTI set IdCrmAzione=14  
				where IdCliente=5318 
				and IdCrmAzione is null 
				and Lotto like '%SPK_CSO%'

			update SPED_LOTTI set IdCrmAzione=15  
				where IdCliente=5318 
				and IdCrmAzione is null 
				and Lotto like '%NIL_CSO%'



	--svuota la palm_raw e ricostruisci gli indici:

	declare @maxid int
	declare @maxnum int
	select MAX(id) from Speedy.dbo.PALM_RAW  where datacreazione<DATEADD(YEAR,-3,GETDATE())
	select @maxnum = COUNT(*) from Speedy.dbo.PALM_RAW where id<@maxid and datacreazione>DATEADD(YEAR,-3,GETDATE())
	if @maxnum=0
		select @maxnum = COUNT(*) from Speedy.dbo.PALM_RAW where id<@maxid and datainserimento>DATEADD(YEAR,-3,GETDATE())
		if @maxnum=0
		begin
-- [rimosso: NotificheDBLogTabelle_2021 non migrato] 			INSERT INTO NotificheDBLogTabelle_2021.dbo.PALM_RAW
-- [rimosso: NotificheDBLogTabelle_2021 non migrato] 					 (id, barcode, tipo, datijson, latitude, longitude, driver, appVersion, imei, datainserimento, datalavorazione, tipoEventoCodice, datacreazione, dataione, risposta, uuid, PrecisioneGPS, DataGPS)
-- [rimosso: NotificheDBLogTabelle_2021 non migrato] 			SELECT  id, barcode, tipo, datijson, latitude, longitude, driver, appVersion, imei, datainserimento, datalavorazione, tipoEventoCodice, datacreazione, dataione, risposta, uuid, PrecisioneGPS, DataGPS
-- [rimosso: NotificheDBLogTabelle_2021 non migrato] 			FROM  Speedy.dbo.PALM_RAW AS PALM_RAW_1
-- [rimosso: NotificheDBLogTabelle_2021 non migrato] 			where id <@maxid
-- [rimosso: NotificheDBLogTabelle_2021 non migrato] 			delete from Speedy.dbo.PALM_RAW where id<@maxid

			ALTER INDEX PK_PALM_RAW ON Speedy.dbo.PALM_RAW REBUILD;
			ALTER INDEX IX_PALMRAW_BARCODE ON Speedy.dbo.PALM_RAW REBUILD;
			ALTER INDEX IX_PALMRAW_DATA ON Speedy.dbo.PALM_RAW REBUILD;
			ALTER INDEX IX_PALMRAW_EVENTO ON Speedy.dbo.PALM_RAW REBUILD;
			ALTER INDEX PALM_RAW_UUID ON Speedy.dbo.PALM_RAW REBUILD;

		end


END

