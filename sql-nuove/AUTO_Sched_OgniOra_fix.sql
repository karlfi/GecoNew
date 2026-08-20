-- =============================================================
-- AUTO_Sched_OgniOra - Schedulazione oraria
--
-- Su questo database mancano oggetti che la procedura richiamava, quindi
-- andava in errore. E' stato commentato il blocco che caricava e rendicontava i flussi ADEX
-- (ADEX_AllineaMySql, ADEX_ImportFlussi, adex_rendiconta).
-- Il resto della procedura e' invariato e continua a funzionare.
--
-- Per riattivare: ricreare prima gli oggetti mancanti, poi togliere il
-- commento. Il file e' la definizione completa: si puo' rieseguire com'e'.
-- =============================================================


-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[AUTO_Sched_OgniOra] 
	-- Add the parameters for the stored procedure here

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	exec UTENTI_AggiornaDati

	delete from PALM_ATTIVITA where isnull(Barcode,'')=''
	
	--exec [POSTE_Aggiorna_Attivita]


	-- DISATTIVATO (agosto 2026): le procedure ADEX_AllineaMySql, ADEX_ImportFlussi e adex_rendiconta non esiste piu' su questo database.
	-- Caricavano i flussi ADEX e ne facevano il rendiconto. Il resto della
	-- procedura oraria (pulizia palmare, coordinate, cartoline restituite)
	-- continua a girare normalmente.
	/*
	--carico i flussi di ADEX
	exec [dbo].[ADEX_AllineaMySql] 
	exec [dbo].[ADEX_ImportFlussi]

	--rendiconto
	exec adex_rendiconta @tipo=1
	*/

	--tolgo gli atti richiamati da flusso eventi
	select distinct sa.IdSpedizione into #tmp1 
	from SPED_ATTIVITA sa
	inner join ADER4_fileEVE fe on fe.IdSpedizione=sa.IdSpedizione and fe.Motivo='A'
	where 1=1
	and sa.Stato not in ('0z','m58')
	and sa.IdLotto>12000

	update  SPED_ATTIVITA set Stato='0Z', IdDistintaLast=null
	from SPED_ATTIVITA sa
	inner join #tmp1 x on x.IdSpedizione=sa.IdSpedizione

	update PALM_ATTIVITA set STATO='02'
	from SPED_ATTIVITA sa
	inner join ADER4_fileEVE fe on fe.IdSpedizione=sa.IdSpedizione and fe.Motivo='A'
	inner join PALM_ATTIVITA pa on convert(int,pa.Riferimento)=sa.IdSpedizione and pa.TipoRiferimento=0
	where 1=1
	and sa.IdLotto>12000
	and pa.STATO='01'

	--aggiorno le coordinate sulla palm_attivita
	update PALM_ATTIVITA set Latitudeprev=sa.DestinazioneLatitude,Longitudeprev=sa.DestinazioneLongitude
	from PALM_ATTIVITA pa (nolock)
	inner join SPED_ATTIVITA sa (nolock) on convert(varchar(20),sa.IdSpedizione)=pa.riferimento 
	where 1=1
	and pa.TipoRiferimento=0
	and pa.Latitude is null
	and sa.DestinazioneLatitude is not null
	and pa.STATO in ('00','01')


	--creo le righe sulla palm per le cartoline restituite
	--la stored è gia presente in RR_CREA ma sembra che non sempre funzioni
	declare @idlotto int

	DECLARE c_lotti CURSOR FOR
	select l.IdLotto
	from SPED_DISTINTE d
	inner join SPED_LOTTI l on l.Lotto='RR-D_'+CONVERT(varchar(10),d.iddistinta)
	left join SPED_ATTIVITA sa on sa.idlotto=l.IdLotto
	left join PALM_ATTIVITA pa on pa.Riferimento=convert(varchar(20),sa.idspedizione) and pa.TipoRiferimento=0
	where d.IdAzione=1035 and d.DataInserimento>GETDATE()-1
	group by d.IdDistinta,l.IdLotto,l.DataCarico,l.NumeroAtti
	having sum(case when pa.IdAttivita is null then 0 else 1 end)=0
	order by 1
	
	OPEN c_lotti
	FETCH NEXT FROM c_lotti INTO @idlotto
	WHILE @@FETCH_STATUS = 0
	begin
		EXEC RR_creaSuPalm @Idlotto=@IdLotto
		FETCH NEXT FROM c_lotti INTO @idlotto
	END
	CLOSE c_lotti
	DEALLOCATE c_lotti
END

