-- =============================================================
-- PALM_ELABORA_BATCH - Elaborazione batch palmare
--
-- Su questo database mancano oggetti che la procedura richiamava, quindi
-- andava in errore. E' stato commentato la chiamata a PALM_RESO_ELABORA_ADER4RACC.
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
CREATE OR ALTER PROCEDURE [dbo].[PALM_ELABORA_BATCH]
	@giorni int=3
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	declare @IdPalm bigint
		,@datainserimento datetime=null
		,@barcode varchar(200)=null
		,@tipo varchar(10)=null
		,@driver varchar(50)=null
		,@datijson varchar(max)=null
		,@appversion varchar(50)=null
		,@imei varchar(50)=null
		,@tipoeventocodice varchar(50)=null
		
	declare @TipoRiferimento int = null 
	declare @IdDipendente int
	declare @NomeDipendente varchar(100)
	declare @accapo varchar(10)=+ CHAR(13)+CHAR(10)
	declare @latitude float
	declare @longitude float
	declare @PrecisioneGPS float 
	declare @Delivery int =0
	declare @jsondriver varchar(50) 
	declare @photoName varchar(50)
		,@stato varchar(50)
		,@nomeFirmatario varchar(50)
		,@qualificaTerzo varchar(50)

	declare cur_palm CURSOR 
		for


		select top 500 
			id,barcode,tipo,datijson,latitude,longitude,PrecisioneGPS
			,driver,appversion,imei,datainserimento,tipoeventocodice
			from PALM_RAW p  (nolock)
			where 1=1
				and datainserimento>GETDATE()-@giorni
				and barcode is not null
				and tipo=0
				and datalavorazione is null
				and tipoEventoCodice <>'X_XX0'
				and tipoEventoCodice <>'X_XX1'
				and tipoEventoCodice <>'S_000'
				and tipoEventoCodice <>'PRT1'
				and tipoEventoCodice <>'PRT2'
				and left(barcode,4)<>'TRG@'
				and left(barcode,4)<>'BAN@'
				and left(barcode,4)<>'ART@'
				and len(barcode)>2
			order by datainserimento,id 

			

	OPEN cur_palm;
	FETCH NEXT FROM cur_palm INTO 
		@IdPalm,@barcode,@tipo,@datijson,@latitude,@longitude,@PrecisioneGPS
			,@driver,@appversion,@imei,@datainserimento,@tipoeventocodice


	WHILE @@FETCH_STATUS = 0
	BEGIN
		print @idpalm
		select @photoName=case when isjson(@datijson)=1 then JSON_VALUE(@datijson,'$.photoName') else null end
			,@stato=case when isjson(@datijson)=1 then JSON_VALUE(@datijson,'$.stato') else null end
			,@nomeFirmatario =case when isjson(@datijson)=1 then JSON_VALUE(@datijson,'$.nomeFirmatario') else null end
			,@qualificaTerzo =case when isjson(@datijson)=1 then JSON_VALUE(@datijson,'$.titoloTerzo') else null end
		from palm_raw where id=@IdPalm

		declare @IdSpedizione int=null

			--declare @log varchar(max)=''
			--set @log=@log+ 'exec deliverydb.dbo.PALM_LOG'
			--set @log=@log+ '	@Barcode ='+@barcode
			--set @log=@log+ '	,@Data ='+convert(varchar(20),@datainserimento)
			--set @log=@log+ '	,@Driver ='+@driver
			--set @log=@log+ '	,@latitude='+convert(varchar(20),@latitude)
			--set @log=@log+ '	,@longitude='+convert(varchar(20),@longitude)
			--set @log=@log+ '	,@photoName ='+@photoName
			--set @log=@log+ '	,@stato ='+@stato
			--set @log=@log+ '	,@tipoEventoCodice ='+@tipoEventoCodice
			--set @log=@log+ '	,@nomeFirmatario ='+@nomeFirmatario
			--set @log=@log+ '	,@qualificaTerzo ='+@qualificaTerzo
			--set @log=@log+ '	,@rowid ='+convert(varchar(20),@IdPalm)
			--print @log
		
		DECLARE	@return_value int
		EXEC	@return_value = deliverydb.dbo.PALM_LOG
			@Barcode =@barcode
			,@Data =@datainserimento
			,@Driver =@driver
			,@latitude=@latitude
			,@longitude=@longitude
			,@PrecisioneGPS=@PrecisioneGPS
			,@photoName =@photoName
			,@stato =@stato
			,@tipoEventoCodice =@tipoEventoCodice
			,@nomeFirmatario =@nomeFirmatario
			,@qualificaTerzo =@qualificaTerzo
			,@rowid =@IdPalm
			,@IdSpedizione=@IdSpedizione output
		with recompile


		update palm_raw set datalavorazione=getdate() where id=@IdPalm
		set @TipoRiferimento =null
		if @IdSpedizione is not null
		begin
			--verifico l'origine
			select @TipoRiferimento=TipoRiferimento from SPED_ATTIVITA where IdSpedizione=@IdSpedizione
			if @TipoRiferimento=1
			begin

			--si richiama il servizio su IONE
			--https://express.speedyworld.it/restapi/set_track.php?barcode=BU010600&tipoeventocodice=S_001&tipoinserimento=A&note=test&stato=stato&utente=aa

				if left(@tipoeventocodice,1) in ('S','R')
				begin
		   			--richiamo il servizio
					DECLARE @url VARCHAR(MAX),
					@win INT,
					@hr INT,
					@Json_result VARCHAR(MAX)
					Set @url = 'https://express.speedyworld.it/restapi/set_track.php?barcode='+@barcode
					Set @url=@url + '&tipoeventocodice='+@TipoEventoCodice
					Set @url=@url + '&tipoinserimento=A'
					Set @url=@url + '&note=-'
					Set @url=@url + '&stato='+case when isjson(@datijson)=1 then JSON_VALUE(@datijson,'$.stato') else '' end
					Set @url=@url + '&utente='+case when isjson(@datijson)=1 then JSON_VALUE(@datijson,'$.driver') else '' end
					EXEC @hr = sp_OACreate 'WinHttp.WinHttpRequest.5.1', @win OUT
					IF @hr <> 0 EXEC sp_OAGetErrorInfo @win
					EXEC @hr = sp_OAMethod @win, 'Open', NULL, 'GET', @url, 'false'
					IF @hr <> 0 EXEC sp_OAGetErrorInfo @win
					EXEC @hr = sp_OAMethod @win, 'Send'
					IF @hr <> 0 EXEC sp_OAGetErrorInfo @win

					Create table #tmp(dt nvarchar(max))
					insert into #tmp
					exec @hr = sp_OAGetProperty @win, 'ResponseText' --,@strLine OUtPUT
					Select @Json_result=dt from #tmp -- single column/single row.
					Drop Table #tmp -- clean up
					IF @hr <> 0 EXEC sp_OAGetErrorInfo @win
					EXEC @hr = sp_OADestroy @win 
					IF @hr <> 0 EXEC sp_OAGetErrorInfo @win 
				end		

			end

			
		end
	FETCH NEXT FROM cur_palm INTO 
		@IdPalm,@barcode,@tipo,@datijson,@latitude,@longitude,@PrecisioneGPS
			,@driver,@appversion,@imei,@datainserimento,@tipoeventocodice

	END;
	CLOSE cur_palm;
	DEALLOCATE cur_palm;
	--print 'PALM_ELABORA_BATCH_LOGIN'
	--exec [PALM_ELABORA_BATCH_LOGIN]  @giorni=1
	--print '[PALM_ELABORA_BATCH_SPED_2IONE]'
	--exec [PALM_ELABORA_BATCH_SPED_2IONE]
	--print 'PALM_ELABORA_SENDEMAIL'
	exec PALM_ELABORA_SENDEMAIL

	--exec SIGN_InserisceRecordDaFirmare

	-- DISATTIVATO (agosto 2026): PALM_RESO_ELABORA_ADER4RACC non esiste piu' su questo database.
	-- Acquisiva gli esiti delle raccomandate ADER4 in chiusura di gita.
	/*
	--acquisisce gli esiti delle raccomandate ader4 sul fine gita
	exec PALM_RESO_ELABORA_ADER4RACC
	*/
END

