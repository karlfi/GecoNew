-- =============================================================
-- PALM_ELABORA_BATCH_LOGIN - Login/logout da palmare
--
-- Su questo database mancano oggetti che la procedura richiamava, quindi
-- andava in errore. E' stato commentato la chiamata a SOTI_AggiornaLoginName.
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
CREATE OR ALTER PROCEDURE [dbo].[PALM_ELABORA_BATCH_LOGIN]
	@giorni int=1
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
	declare @Delivery int =0
	declare @jsondriver varchar(50) 
	declare @photoName varchar(50)
		,@stato varchar(50)
		,@nomeFirmatario varchar(50)
		,@qualificaTerzo varchar(50)

	declare cur_palm_login CURSOR 
		for

		--controllo solo i login
		select top 1 
			id,barcode,tipo,datijson,latitude,longitude
			,driver,appversion,imei,datainserimento,tipoeventocodice
			from PALM_RAW p 
			where 1=1
				and datainserimento>GETDATE()-@giorni
				and barcode is not null
				and tipo=0
				and datalavorazione is null
				and tipoEventoCodice in ('X_XX1','X_XX0')
				and LEN(imei)=14
				and left(barcode,4)<>'TRG@'
				and len(barcode)>2
			order by datainserimento,id 

			

	OPEN cur_palm_login;
	FETCH NEXT FROM cur_palm_login INTO 
		@IdPalm,@barcode,@tipo,@datijson,@latitude,@longitude
			,@driver,@appversion,@imei,@datainserimento,@tipoeventocodice


	WHILE @@FETCH_STATUS = 0
	BEGIN
		
		set @tipo=case when @tipoeventocodice='X_XX1' then 'logIN:' else 'logOUT:' end
		-- DISATTIVATO (agosto 2026): SOTI_AggiornaLoginName non esiste piu' su questo database.
		-- Riportava su SOTI il nome di login del palmare. Il ciclo prosegue e
		-- continua a marcare le righe come lavorate (update palm_raw qui sotto).
		/*
		EXEC	SOTI_AggiornaLoginName
			@Seriale=@imei
			,@codAppLogin =@barcode
			,@tipo =@tipo
			,@data=@datainserimento
		*/

			update palm_raw set datalavorazione=getdate() where id=@IdPalm

		FETCH NEXT FROM cur_palm_login INTO 
		@IdPalm,@barcode,@tipo,@datijson,@latitude,@longitude
			,@driver,@appversion,@imei,@datainserimento,@tipoeventocodice

	END;
	CLOSE cur_palm_login;
	DEALLOCATE cur_palm_login;
END

