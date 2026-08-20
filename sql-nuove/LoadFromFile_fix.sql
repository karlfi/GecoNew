-- =============================================================
-- LoadFromFile - Caricamento lotti da file
--
-- Su questo database mancano oggetti che la procedura richiamava, quindi
-- andava in errore. E' stato commentato il calcolo del listino per i file CONSIP
-- (funzione getlistinoconsip), insieme all'IF che lo conteneva.
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
CREATE OR ALTER PROCEDURE [dbo].[LoadFromFile]
	-- Add the parameters for the stored procedure here
	@DocID varchar(50)
	,@NomeFile varchar(250)
	,@IdCliente int =0
	,@IdProdotto int =0
	,@SoloVerifica int = 1
	,@IdUtente int = null
	,@IdFiliale int = null
	,@idmittente int = null
	,@IdFattListino int=null
	,@TipoFile int =1                  --tipo 1 = CSV 19 campi - formato FC
	                                   --tipo 2 = FATTURE ESTRA
									   --tipo 3 = RACCOMANDATE ESTRA
									   --tipo 4 = SISPI certificate
									   --tipo 5 = Raccomandate Comune Palermo
									   --tipo 6 = Sidra ordinarie
									   --tipo 7
									   --tipo 8 = file SPC002 tipo ALIA
									   --tipo 9
									   --tipo 10 = SNEM - AFM
									   --tipo 11 = file FULMINE
									   --tipo 12 ;
									   --tipo 13 AFF3 Nexive
									   --tipo 14 CONSIP
									   --tipo 16 POSTE DU
									   --tipo 18 Notifiche SR
									   --tipo 19
									   --tipo 20
									   --tipo 21 File SPIKE
	,@Esito varchar(250) =null OUTPUT
	
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    -- Insert statements for procedure here
	set @Esito='Anomalia'
	declare @num as int=0

	declare @var1 varchar(50)
	declare @var2 varchar(50)
	declare @var3 varchar(50)
	declare @var4 varchar(50)
	declare @var5 varchar(50)
	

	declare @Comando varchar(200)=''
	set @Comando='Scrittura Log'
	print 'scrittura log'
	insert into log_exec (chiamata,parametri,datainserimento)
	select 'LoadFromFile'
		,left(
		isnull(' @DocID='+convert(varchar(50),@DocID),'')
		+isnull(',@NomeFile='+@NomeFile,'')
		+isnull(',@IdCliente='+convert(varchar(20),@IdCliente),'')
		+isnull(',@IdProdotto='+convert(varchar(20),@IdProdotto),'')
		+isnull(',@SoloVerifica='+convert(varchar(20),@SoloVerifica),'')

		+isnull(',@IdFiliale='+convert(varchar(20),@IdFiliale),'')
		+isnull(',@IdUtente='+convert(varchar(20),@IdUtente),'')
		+isnull(',@idmittente='+convert(varchar(20),@idmittente),'')
		+isnull(',@IdFattListino='+convert(varchar(20),@IdFattListino),'')
		+isnull(',@TipoFile='+convert(varchar(20),@TipoFile),'')
		,4000)
		,getdate()


	begin try
		print 'inizio try'
		if isnull(@IdFattListino,0)<>0 and ISNULL(@IdProdotto,0)=0
			select @IdProdotto=IdProdotto from FATT_LISTINI where IdListino=@IdFattListino

		--controllo che ci sia il file richiesto nella tabella
		select @num =COUNT(*) from FILE_LOAD where DocID=@DocID and nomefile=@nomefile
		if @num=0
		begin
			set @Esito='il file richiesto non esiste '+ @NomeFile +' - ' + @DocID
			raiserror( @Esito, 16,1)
		end


		if not(@tipofile in (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21))
		begin
			set @Esito='La tipologia di tracciato non esiste '+ @NomeFile +' - ' + @DocID
			raiserror( @Esito, 16,1)
		end
		
		
		--leggo i parametri del tipo di tracciato 
		declare @Separatore varchar(50)=';'
		declare @NumColonne int=19
		declare @RigheIntestazione int=0
		declare @RigheFooter int=0
		declare @NumRighe int=0
		select @Separatore=Separatore
			,@NumColonne=ColonneTotali
			,@RigheIntestazione=isnull(RigheIntestazione,0)
			,@RigheFooter=ISNULL(RigheFooter,0)
			from FILE_TRACCIATO where IdTracciato =@tipofile
		


		declare @SepBackup varchar(50)=@Separatore
		declare @NumColBackup int = @NumColonne
		if isnull(@Separatore,'') =''
		begin	
			set @Separatore='|'
			set @NumColonne=1
		end
		print 'insert in #tmpv'
		--carico in #tmpv il file spezzettato per riga colonna e valore 
			SELECT riga,x.*
				into #tmpv
				from (
					select ROW_NUMBER() OVER(ORDER BY idfileload ASC) as riga ,testo from FILE_LOAD
					where DocID=@DOCID and NomeFile=@NomeFile
				) f
				cross apply SplitString(f.testo,@Separatore) x


		print 'primo set di controllo'
		--controllo la corrispondenza del file al modello
		declare @m int

		--controllo se ci sono tutte le righe
		select @m =MAX(riga) from #tmpv
		if @m<>@num begin
			set @Esito='Righe del file incongruenti, attese '+ convert(varchar(10),@num)+', trovate ' + CONVERT(varchar(10),@m)
			raiserror( @Esito, 16,1)
		end
		
		--Controllo se ci sono tutte le colonne
		select @m =max(position) from #tmpv
		if @m>@NumColonne begin 
			set @esito='Il file ha troppe colonne, attese' + convert(varchar(10),@numcolonne)+',trovate ' + convert(varchar(10),@m)
			raiserror( @Esito, 16,1)
		end
		select @m =count(*) from #tmpv where position=@NumColonne
		
		--correggere con intestazione e footer corretti
		if @m<>@num and @righeintestazione=0 begin
			set @esito='Il file non ha tutte le colonne attese'
			raiserror( @Esito, 16,1)
		end

		set @Esito='Controlli sul file OK'


		if @SoloVerifica=0
		begin
			if @IdProdotto is null raiserror ('Tipo Prodotto non selezionato',16,1)
			if @IdCliente =0 raiserror ('Cliente non selezionato',16,1)

		print 'creo tabella #tmpF'
		--creo la tabella #tmpf con le colonne del file, tutte di tipo varchar max
		create table #tmpF (
					riga int 
					,id int identity(1,1)
					,testo varchar(max)
					,col0 varchar(max)
					,col1 varchar(max)
					,col2 varchar(max)
					,col3 varchar(max)
					,col4 varchar(max)
					,col5 varchar(max)
					,col6 varchar(max)
					,col7 varchar(max)
					,col8 varchar(max)
					,col9 varchar(max)
					,col10 varchar(max)
					,col11 varchar(max)
					,col12 varchar(max)
					,col13 varchar(max)
					,col14 varchar(max)
					,col15 varchar(max)
					,col16 varchar(max)
					,col17 varchar(max)
					,col18 varchar(max)
					,col19 varchar(max)
					,col20 varchar(max)
					,col21 varchar(max)
					,col22 varchar(max)
					,col23 varchar(max)
					,col24 varchar(max)
					,col25 varchar(max)
					,col26 varchar(max)
					,col27 varchar(max)
					,col28 varchar(max)
					,col29 varchar(max)
					,col30 varchar(max)
					,col31 varchar(max)
					,col32 varchar(max)
					,col33 varchar(max)
					,col34 varchar(max)
					,col35 varchar(max)
					,col36 varchar(max)
					,col37 varchar(max)
					,col38 varchar(max)
					,col39 varchar(max)			
				)
		--posso aggoingere anche piu colonne rispetto a quelle presenti nel file, le eccedenze avranno contenuto NULL
		if isnull(@SepBackup,'') =''
		begin	
			set @Separatore=@SepBackup
			set @NumColonne=@NumColBackup
		end
		
		--if isnull(@Separatore,'') <>''
		if (@tipofile <10 or @TipoFile in (11,12,13,14,16,17,18,19,20,21) )
		begin
			print 'insert into tabella #tmpF'
			insert into #tmpf (col0,col1,col2,col3,col4,col5,col6,col7,col8,col9
							,col10,col11,col12,col13,col14,col15,col16,col17,col18,col19
							,col20,col21,col22,col23,col24,col25,col26,col27,col28,col29
							,col30,col31,col32,col33,col34,col35,col36,col37,col38,col39
							,riga)
			Select B.*,a.riga
							--into #tmpf
				From  (
 								select ROW_NUMBER() OVER(ORDER BY idfileload ASC) as riga ,dbo.replacenonansii(testo,1) as testo from FILE_LOAD
								where DocID=@DOCID and NomeFile=@NomeFile
				) A
				Cross Apply (
					Select col0 =   upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[1]','varchar(max)'),-1))))
							,col1 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[2]','varchar(max)'),-1))))
							,col2 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[3]','varchar(max)'),-1))))
							,col3 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[4]','varchar(max)'),-1))))
							,col4 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[5]','varchar(max)'),-1))))
							,col5 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[6]','varchar(max)'),-1))))
							,col6 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[7]','varchar(max)'),-1))))
							,col7 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[8]','varchar(max)'),-1))))
							,col8 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[9]','varchar(max)'),-1))))
							,col9 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[10]','varchar(max)'),-1))))
							,col10 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[11]','varchar(max)'),-1))))
							,col11 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[12]','varchar(max)'),-1))))
							,col12 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[13]','varchar(max)'),-1))))
							,col13 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[14]','varchar(max)'),-1))))
							,col14 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[15]','varchar(max)'),-1))))
							,col15 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[16]','varchar(max)'),-1))))
							,col16 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[17]','varchar(max)'),-1))))
							,col17 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[18]','varchar(max)'),-1))))
							,col18 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[19]','varchar(max)'),-1))))
							,col19 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[20]','varchar(max)'),-1))))

							,col20 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[21]','varchar(max)'),-1))))
							,col21 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[22]','varchar(max)'),-1))))
							,col22 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[23]','varchar(max)'),-1))))
							,col23 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[24]','varchar(max)'),-1))))
							,col24 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[25]','varchar(max)'),-1))))
							,col25 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[26]','varchar(max)'),-1))))
							,col26 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[27]','varchar(max)'),-1))))
							,col27 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[28]','varchar(max)'),-1))))
							,col28 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[29]','varchar(max)'),-1))))
							,col29 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[30]','varchar(max)'),-1))))

							,col30 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[31]','varchar(max)'),-1))))
							,col31 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[32]','varchar(max)'),-1))))
							,col32 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[33]','varchar(max)'),-1))))
							,col33 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[34]','varchar(max)'),-1))))
							,col34 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[35]','varchar(max)'),-1))))
							,col35 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[36]','varchar(max)'),-1))))
							,col36 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[37]','varchar(max)'),-1))))
							,col37 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[38]','varchar(max)'),-1))))
							,col38 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[39]','varchar(max)'),-1))))
							,col39 = upper(ltrim(rtrim(dbo.replacenonansii(xDim.value('/x[40]','varchar(max)'),-1))))


						From (Select Cast('<x>' + Replace(A.testo,@Separatore,'</x><x>')+'</x>' as XML) as xDim) A
					) B
					order by riga
			end
			else
			begin
			--select * from FILE_TRACCIATOCAMPI tc
			--where tc.IdTracciato=@tipofile
			
			--barcode,destinatario,indirizzo,cap,localita,prov
				--riferimento1,mittente,mittenteind,cap,localita,prov
				--nota1,2,3,4
				if @TipoFile=10
				begin
				insert into #tmpf (col0,col1,col2,col3,col4,col5,col6,col7,col8,col9,col10,col11,col12,col13,col14,col15,col16,col17,col18)
				select 
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Barcode' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Barcode' and IdTracciato=@TipoFile) 
					) col0,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_Nominativo' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_Nominativo' and IdTracciato=@TipoFile) 
					) col1,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_Indirizzo' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_Indirizzo' and IdTracciato=@TipoFile) 
					) col2,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_Cap' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_Cap' and IdTracciato=@TipoFile) 
					) col3,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_Localita' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_Localita' and IdTracciato=@TipoFile) 
					) col4,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_Prov' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_Prov' and IdTracciato=@TipoFile) 
					) col5,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_CFisc' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_CFisc' and IdTracciato=@TipoFile) 
					) col6,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Mitt_Nominativo' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Mitt_Nominativo' and IdTracciato=@TipoFile) 
					) col7,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Mitt_Indirizzo' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Mitt_Indirizzo' and IdTracciato=@TipoFile) 
					) col8,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Mitt_Cap' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Mitt_Cap' and IdTracciato=@TipoFile) 
					) col9,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Mitt_Localita' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Mitt_Localita' and IdTracciato=@TipoFile) 
					) col10,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Mitt_Prov' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Mitt_Prov' and IdTracciato=@TipoFile) 
					) col11,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='RiferimentoEsterno1' and IdTracciato=10)
					,(select lungh from file_tracciatocampi where CampoTabella='RiferimentoEsterno1' and IdTracciato=10) 
					) col12,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='RiferimentoEsterno2' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='RiferimentoEsterno2' and IdTracciato=@TipoFile) 
					) col13,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Nota1' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Nota1' and IdTracciato=@TipoFile) 
					) col14,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Nota2' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Nota2' and IdTracciato=@TipoFile) 
					) col15,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Nota3' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Nota3' and IdTracciato=@TipoFile) 
					) col16,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Nota4' and IdTracciato=10)
					,(select lungh from file_tracciatocampi where CampoTabella='Nota4' and IdTracciato=10) 
					) col17,
					SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Dest_Cellulare' and IdTracciato=10)
					,(select lungh from file_tracciatocampi where CampoTabella='Dest_Cellulare' and IdTracciato=10) 
					) col18
					
				from FILE_LOAD f 
				where DocID=@DOCID and NomeFile=@NomeFile
				and
				TRIM(SUBSTRING(f.Testo
					,(select da from file_tracciatocampi where CampoTabella='Barcode' and IdTracciato=@TipoFile)
					,(select lungh from file_tracciatocampi where CampoTabella='Barcode' and IdTracciato=@TipoFile) 
					))<>''
				and SUBSTRING(f.testo,8,2)='77'--aggiunto per gestire i flussi SNEM SORI
				order by f.IdFileLoad

				update #tmpf set riga=id
				end
			end

			--riordino le colonne di #tmpf
			if @TipoFile in (12,13,14,16,21)
			begin
				print 'riordino le colonne di #tmpf'
				create table #tmpG (
							riga int 
							,id int identity(1,1)
							,testo varchar(max)
					,col0 varchar(max)
					,col1 varchar(max)
					,col2 varchar(max)
					,col3 varchar(max)
					,col4 varchar(max)
					,col5 varchar(max)
					,col6 varchar(max)
					,col7 varchar(max)
					,col8 varchar(max)
					,col9 varchar(max)
					,col10 varchar(max)
					,col11 varchar(max)
					,col12 varchar(max)
					,col13 varchar(max)
					,col14 varchar(max)
					,col15 varchar(max)
					,col16 varchar(max)
					,col17 varchar(max)
					,col18 varchar(max)
					,col19 varchar(max)
					,col20 varchar(max)
					,col21 varchar(max)
					,col22 varchar(max)
					,col23 varchar(max)
					,col24 varchar(max)
					,col25 varchar(max)
					,col26 varchar(max)
					,col27 varchar(max)
					,col28 varchar(max)
					,col29 varchar(max)
					,col30 varchar(max)
					,col31 varchar(max)
					,col32 varchar(max)
					,col33 varchar(max)
					,col34 varchar(max)
					,col35 varchar(max)
					,col36 varchar(max)
					,col37 varchar(max)
					,col38 varchar(max)
					,col39 varchar(max)	
				)

				declare @Exec nvarchar(max)=''
				declare 	@col0 varchar(10)	,@col1 varchar(10)	,@col2 varchar(10)	,@col3 varchar(10)	,@col4 varchar(10)
					,@col5 varchar(10) ,@col6 varchar(10) ,@col7 varchar(10) ,@col8 varchar(10)	,@col9 varchar(10)	
					,@col10 varchar(10)	,@col11 varchar(10)	,@col12 varchar(10)	,@col13 varchar(10)	,@col14 varchar(10)	
					,@col15 varchar(10)	,@col16 varchar(10)	,@col17 varchar(10)	,@col18 varchar(10)	,@col19 varchar(10)
					--,@col20 varchar(10)	,@col21 varchar(10)	,@col22 varchar(10)	,@col23 varchar(10)	,@col24 varchar(10)	
					--,@col25 varchar(10)	,@col26 varchar(10)	,@col27 varchar(10)	,@col28 varchar(10)	,@col29 varchar(10)
					--,@col30 varchar(10)	,@col31 varchar(10)	,@col32 varchar(10)	,@col33 varchar(10)	,@col34 varchar(10)	
					--,@col35 varchar(10)	,@col36 varchar(10)	,@col37 varchar(10)	,@col38 varchar(10)	,@col39 varchar(10)
	
				select @col0=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Barcode'
				select @col1=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_Nominativo'
				select @col2=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_Indirizzo'
				select @col3=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_Cap'
				select @col4=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_Localita'
				select @col5=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_Prov'
				select @col6=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_CFisc'
				select @col7=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Mitt_Nominativo'
				select @col8=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Mitt_Indirizzo'
				select @col9=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Mitt_Cap'
				select @col10=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Mitt_Localita'
				select @col11=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Mitt_Prov'
				select @col12=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='RiferimentoEsterno1'
				select @col13=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='RiferimentoEsterno2'
				select @col14=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Nota1'
				select @col15=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Nota2'
				select @col16=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Nota3'
				select @col17=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Nota4'
				select @col18=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Dest_Cellulare'
				select @col19=convert(varchar(10),progressivo-1) from file_tracciatocampi where idtracciato=@tipofile and campotabella='Peso'


				set @exec='insert into #tmpG (col0,col1,col2,col3,col4,col5,col6,col7,col8,col9,col10,col11,col12,col13,col14,col15,col16,col17,col18,col19) '
				select @exec=@exec + 'select '+isnull('col'+@col0,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col1,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col2,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col3,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col4,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col5,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col6,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col7,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col8,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col9,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col10,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col11,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col12,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col13,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col14,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col15,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col16,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col17,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col18,char(39)+char(39))
				select @exec=@exec + ' ,'+isnull('col'+@col19,char(39)+char(39))
				select @exec=@exec + ' from #tmpF order by id'
				EXECUTE sp_executesql @statement=@exec
				--select * from #tmpG

				truncate table #tmpF
				insert into #tmpF (col0,col1,col2,col3,col4,col5,col6,col7,col8,col9,col10,col11,col12,col13,col14,col15,col16,col17,col18,col19)
				select col0,col1,col2,col3,col4,col5,col6,col7,col8,col9,col10,col11,col12,col13,col14,col15,col16,col17,col18,col19 from #tmpG
				order by id
				update #tmpf set riga=id
			end


		--prima di cancellare le righe di intestazione, se siamo in tipo=16 prendo due var dalla prima riga
		if @TipoFile=16
		begin
			select @var1=col4 from #tmpf where riga=1
			select @var2=col5 from #tmpf where riga=1
		end
		--cancello le righe di intestazione
		if isnull(@RigheIntestazione,0)>0
		begin
			delete from #tmpf where riga<=@RigheIntestazione
			update #tmpf set riga=riga-@RigheIntestazione
			set @num=@num-@RigheIntestazione
		end
		--cancello le righe del footer
		if isnull(@RigheFooter,0)>0
		begin
			declare @maxrighe int 
			select @maxrighe=max(riga) from #tmpf
			delete from #tmpf where riga>@maxrighe-@RigheFooter
			set @num=@num-@RigheFooter
		end


		--verifico se ci sono barcode gia presenti
		--in questo momento il controllo è su tutto SPED_ATTIVITA ma dovremmo filtrarlo meglio
		declare @ripetuti int 
		declare @msg varchar(100)=''

		if @TipoFile in (1,2,3,4,5,6,10,11,14,18,21)
			select @ripetuti=COUNT(*)
				from SPED_ATTIVITA s
				inner join #tmpf x on x.col0=s.barcode
				where s.DataFine is null

		if @TipoFile in (16)
			select @ripetuti=COUNT(*)
				from SPED_ATTIVITA s
				inner join #tmpf x on right(x.col12,50)=s.barcode
				where s.DataFine is null	
				
		if @TipoFile in (7)
			select @ripetuti=COUNT(*) 
			from SPED_ATTIVITA s
			inner join #tmpf x on x.col14=s.barcode
			where s.DataFine is null

		if @TipoFile in (8)
			select @ripetuti=COUNT(*) 
			from SPED_ATTIVITA s
			inner join #tmpf x on x.col1=s.barcode
			where s.DataFine is null
		
		if @ripetuti>0 begin
			set @esito='Nel flusso ci sono ' + CONVERT(varchar(10),@ripetuti) + ' Barcode gia presenti'
			raiserror( @Esito, 16,1)
		end

		--verifico se ci sono barcode ripetuti nel file
		if @TipoFile in (1,2,3,4,5,6,10,11,13,14,18,21)
		begin
			select @ripetuti=COUNT(*) 
				from 
				(select x.col0,count(*) as num
				from  #tmpf x
				group by x.col0
				having count(*)>1) x
		
			select @msg=x.col0
				from  #tmpf x
				group by x.col0
				having count(*)>1
		end

		if @TipoFile in (7)
		select @ripetuti=COUNT(*) from 
			(select x.col14,count(*) as num
			from  #tmpf x
			group by x.col14
			having count(*)>1) x

		if @TipoFile in (8)
		select @ripetuti=COUNT(*) from 
			(select x.col1,count(*) as num
			from  #tmpf x
			group by x.col1
			having count(*)>1) x

		if @ripetuti>0 begin
			set @esito='Nel flusso ci sono '+convert(varchar(10),@ripetuti)+' Barcode duplicati nel file'
			if isnull(@msg,'')<>''
				set @Esito=@Esito + ', es. barcode:' + @msg
			raiserror( @Esito, 16,1)
		end

		declare @codfamiglia varchar(5) 
		declare @idlotto int
		declare @IdProdottoCollegato int
		declare @codfamiglia_RR varchar(5)
		declare @IdLotto_RR int
		----creo il lotto	
		begin transaction tr1
			begin try

				select @codfamiglia=codfamiglia,@IdProdottoCollegato=IdProdottoCollegato 
					from PRODOTTI where IdProdotto =@IdProdotto

				--determino l'indirizzo del cliente, puo servirmi come indirizzo mittente
				declare @Cli_Ragionesociale varchar(max)
						,@Cli_Indirizzo varchar(max)
						,@Cli_Comune varchar(max)
						,@Cli_cap varchar(max)
						,@Cli_prov varchar(max)						
				select @Cli_Ragionesociale=c.RagioneSociale
					,@Cli_Indirizzo=c.Indirizzo
					,@Cli_Comune=c.Comune
					,@Cli_cap=c.CAP
					,@Cli_prov=c.Prov from CLIENTI c where IdCliente=@IdCliente

				print 'creo il lotto'
				set @Esito='Inserimento del lotto'
				insert into SPED_LOTTI (Lotto,IdCliente,DataCarico,DataInserimento,datavideocodifica,NumeroAtti,IdProdotto,IdUtente,IdFilialeAccettazione,CodFamiglia)
				select left(@NomeFile,50),@IdCliente,GETDATE(),GETDATE(),GETDATE(),@num,@IdProdotto,@IdUtente,@IdFiliale,@codfamiglia
				set @idlotto=SCOPE_IDENTITY()
				if @TipoFile=16  update SPED_LOTTI set dataposte=@var1,frazionarioposte=@var2 where IdLotto=@idlotto
				--se sono documenti con Ricevute di Ritorno creo anche il lotto collegato. Aggiungo anche la data accettazione
				--2022-09-06 tolgo la creazione del lotto collegato, le ricevute di ritorno vengono gestite direttamente nella spedizione
				--if @IdProdottoCollegato is not null
				--begin 
				--	insert into SPED_LOTTI (Lotto,IdCliente,DataCarico,DataAccettazione,DataInserimento,datavideocodifica,NumeroAtti,IdProdotto,IdUtente,IdFilialeAccettazione,CodFamiglia)
				--	select 'RR_'+@NomeFile,@IdCliente,GETDATE(),getdate(),getdate(),GETDATE(),@num,@IdProdottoCollegato,@IdUtente,@IdFiliale,@codfamiglia_RR
				--	set @IdLotto_RR=SCOPE_IDENTITY()
				--end
				print 'inserisco le righe'
				set @Esito='Inserimento delle righe'
				if @tipofile=1
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,RiferimentoEsterno1,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,NOTA1,NOTA2
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',upper(col0),@IdCliente,GETDATE(),@IdProdotto
						,upper(col4),upper(col5),upper(col6),upper(col7),upper(col8)
						--,upper(col11),upper(col12),upper(col13+ISNULL(' '+col14,'')),upper(col15),upper(col16),upper(col17)
						,upper(col11),upper(col12),upper(col13),upper(col15),upper(col16),upper(col17),upper(col18)
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col6,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col6,dbo.getbelfiore(col7,col8),@IdProdotto)
						--,@IdFiliale,dbo.GetCoperturaFiliale('D',col6,null,null),dbo.GetCoperturaFiliale('G',col6,null,null)
					from #tmpf
					order by #tmpf.id

				end
				if @tipofile=2
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,RiferimentoEsterno1
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice						
						,NOTA1,NOTA2,NOTA3
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col0,@IdCliente,GETDATE(),@IdProdotto
						,col3,col4,col6,col7,col8
						,col0
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,col10,col11,col12
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col6,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col6,dbo.getbelfiore(col7,col8),@IdProdotto)
						--,@IdFiliale,dbo.GetCoperturaFiliale('D',col6,null,null),dbo.GetCoperturaFiliale('G',col6,null,null)
					from #tmpf
					order by #tmpf.id
				end
				if @tipofile=3
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,RiferimentoEsterno1
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice
						,NOTA1,NOTA2,NOTA3
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col0,@IdCliente,GETDATE(),@IdProdotto
						,col4,col5,col7,col8,col9
						,col1
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,col11,col12,col13
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col7,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col7,dbo.getbelfiore(col8,col9),@IdProdotto)
					from #tmpf
					order by #tmpf.id
				end			
				if @tipofile=4
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,RiferimentoEsterno1
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice						
						,NOTA1,NOTA2
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col0,@IdCliente,GETDATE(),@IdProdotto
						,col1,col2+', ' + col3,col4,col5,col6
						,col0
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,col7,col8
						,dbo.GetCoperturaFiliale('D',col4,null,@IdProdotto),dbo.GetCoperturaFiliale('D',col4,null,null),dbo.GetCoperturaFiliale('G',col4,dbo.getbelfiore(col5,col6),@IdProdotto)
					from #tmpf
					order by #tmpf.id
				end			
				if @tipofile=5
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,RiferimentoEsterno1,NOTA1
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice						
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col0,@IdCliente,GETDATE(),@IdProdotto
						,col1,col2+' '+col3,col4,col5,col6
						,case when isnull(p.IdProdottoCollegato,0)=28 then
							case when isnull(col8,'')='' then 'CSOC'+col0 else col8 end
						 else '' end,col7
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col4,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col4,dbo.getbelfiore(col5,col6),@IdProdotto)
					from #tmpf
						inner join PRODOTTI p on p.IdProdotto=@IdProdotto
					order by #tmpf.id
				end
				if @tipofile=6
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,NOTA1
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice						
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col0,@IdCliente,GETDATE(),@IdProdotto
						,col1,col2+' '+col3,col4,col5,col6
						 ,col7
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,dbo.GetCoperturaFiliale('D',col4,null,@IdProdotto),dbo.GetCoperturaFiliale('D',col4,null,null),dbo.GetCoperturaFiliale('G',col4,dbo.getbelfiore(col5,col6),@IdProdotto)
					from #tmpf
						inner join PRODOTTI p on p.IdProdotto=@IdProdotto
					order by #tmpf.id
				end
				if @tipofile=7
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice
						,NOTA1,NOTA2,NOTA3,NOTA4
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col14,@IdCliente,GETDATE(),@IdProdotto
						,col2,col11,left(col12,5),replace(replace(col12,left(col12,5),''),right(rtrim(col12),2),''),right(rtrim(col12),2)
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,col3,col4,col5,col1										
						,dbo.GetCoperturaFiliale('D',left(col12,5),null,@IdProdotto),dbo.GetCoperturaFiliale('D',left(col12,5),null,null),dbo.GetCoperturaFiliale('G',left(col12,5),null,@IdProdotto)
					from #tmpf
					order by #tmpf.id
				end
				if @tipofile=8
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice		
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice
						,NOTA1,DestinazioneCodiceFiscale,NOTA4
						,RiferimentoEsterno1,RiferimentoEsterno2,NOTA2,NOTA3
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						)
					select @idlotto,'',col1,@IdCliente,GETDATE(),@IdProdotto
						,col3,col4,col5,col6,col7
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,col8,col2,col13
						,col9,col10,col11,col12
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col5,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col5,dbo.getbelfiore(col6,col7),@IdProdotto)
					from #tmpf
					--where riga>isnull(@RigheIntestazione,0)
					order by #tmpf.id
				end
				if @TipoFile=9
				begin
					----Cancello intestazioni
					delete from #tmpf where col0='PROG_STAMPA'

					--Divido Comune e Sigla prov
					update #tmpf set col6=case when PATINDEX('%(%',col6)>0 then left(col6,PATINDEX('%(%',col6)-1) else col6 end
					,col4=case when PATINDEX('%(%',col6)>0 then replace(substring(col6,PATINDEX('%(%',col6)+1,3),')','') else '' end

					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
							,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
							,RiferimentoEsterno1,NOTA1
							,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice						
							,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
							)
						select @idlotto,'',col9,@IdCliente,GETDATE(),@IdProdotto
							,col1,col3,col5,col6,col4
							,col10,col7+'-'+col8
							,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
							,@IdFiliale,dbo.GetCoperturaFiliale('D',col5,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col5,dbo.getbelfiore(col6,col4),@IdProdotto)
						from #tmpf
							inner join PRODOTTI p on p.IdProdotto=@IdProdotto
						order by #tmpf.id
				end

				if @tipofile in (10,12,13,14,16,21)
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,DestinazioneCodiceFiscale
						,RiferimentoEsterno1,RiferimentoEsterno2
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,MittenteProvinciaCodice
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						,nota1,NOTA2,nota3,nota4
						,ContattoDestTelefono
						,PortoPeso
						)  --[ReplaceNonASCII]
					select @idlotto,'',upper(col0),@IdCliente,GETDATE(),@IdProdotto
						,left(trim(upper(col1)),200),left(trim(upper(col2)),200),left(trim(upper(col3)),5),left(trim(upper(col4)),200),left(trim(upper(col5)),2)
						,left(trim(upper(col6)),16)
						,left(trim(upper(col12)),200),left(trim(upper(col13)),200)
						,left(trim(upper(col7)),200),left(trim(upper(col8)),200),left(trim(upper(col9)),5),left(trim(upper(col10)),200),left(trim(upper(col11)),2)
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col3,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col3,dbo.getbelfiore(col4,col5),@IdProdotto)
						,left(trim(upper(col14)),200),left(trim(upper(col15)),200),left(trim(upper(col16)),200),left(trim(upper(col17)),200)
						,left(trim(upper(col18)),50)
						,left(trim(upper(col19)),50)
					from #tmpf
					order by #tmpf.id



					if @tipofile=16 --se Poste DU, il barcode sono gli ultimi 50 caratteri di rifesterno1 
					begin
						update SPED_ATTIVITA set barcode=right(sa.riferimentoesterno1,50)
						from SPED_ATTIVITA sa 
							where sa.IdLotto=@idlotto
					end
					
					if @tipofile in (14)  --SE Consip -- correggo i prodotti e idcrmazione sul lotto (serve per la rendicontazione esiti)
					begin  
						--se consip
						update SPED_ATTIVITA set IdProdotto=p.IdProdotto
						from SPED_ATTIVITA sa 
							inner join PRODOTTI p on p.CodConsip=sa.RiferimentoEsterno2
							where sa.IdLotto=@idlotto
							and p.IdProdotto<70
							and sa.IdCliente=5318

						--se consip (spike si rendiconta con le api)
						update SPED_LOTTI
							set idcrmazione=case when left(l.lotto,7) ='AFF_CRC' then 13
												 when left(l.lotto,7) ='AFF_SPK' then 14
												 when left(l.lotto,7) ='AFF_NIL' then 15 end
						from SPED_LOTTI l 
						where l.IdLotto=@idlotto
					end
					if @tipofile in (21)  --SE Consip -- correggo i prodotti e idcrmazione sul lotto (serve per la rendicontazione esiti)
					begin  
						--se spike
						update SPED_ATTIVITA set IdProdotto=p.IdProdotto
						from SPED_ATTIVITA sa 
							inner join PRODOTTI p on p.Codspike=sa.RiferimentoEsterno2
							where sa.IdLotto=@idlotto
							and sa.IdCliente=5399
						update sped_lotti set IdProdotto=p.IdProdotto
						from sped_lotti l
						inner join SPED_ATTIVITA sa on sa.IdLotto=l.IdLotto
							inner join PRODOTTI p on p.Codspike=sa.RiferimentoEsterno2
							where sa.IdLotto=@idlotto
							and sa.IdCliente=5399

						--se ag
						update SPED_ATTIVITA set RiferimentoEsterno2 ='CAD'+sa.Barcode
											,RiferimentoEsterno3='CAN'+sa.Barcode
						from SPED_ATTIVITA sa 
							where sa.IdLotto=@idlotto
							and sa.IdCliente=5399
							and sa.IdProdotto=12
					end
				end

				if @tipofile=18 --Notifiche Comune Siracusa
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneNumeroCivico,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,DestinazioneCodiceFiscale
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						,nota1,nota2						
						)
					select @idlotto,'',upper(col0),@IdCliente,GETDATE(),@IdProdotto
						,left(trim(upper(col1)),200),left(trim(upper(col2)),200),left(trim(upper(col3)),200),left(trim(upper(col4)),5),left(trim(upper(col5)),200),left(trim(upper(col6)),2)
						,left(trim(upper(col7)),16)
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col4,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col4,dbo.getbelfiore(col5,col6),@IdProdotto)
						,left(trim(upper(col8)),200),left(trim(upper(col9)),200)						
					from #tmpf
				end


				if @tipofile=19 --AR Riesi
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,DestinazioneCodiceFiscale,RiferimentoEsterno1
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza					
						)
					select @idlotto,'',upper(col6),@IdCliente,GETDATE(),@IdProdotto
						,left(trim(upper(col0)),200),left(trim(upper(col2)),200),left(trim(upper(col3)),200),left(trim(upper(col4)),5),left(trim(upper(col5)),200)
						,left(trim(upper(col1)),16),upper(col7)
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col3,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col3,dbo.getbelfiore(col4,col5),@IdProdotto)						
					from #tmpf
				end


				if @tipofile=11
				begin	
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
						,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
						,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,MittenteProvinciaCodice
						,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
						,NOTA2,nota3
						,ContattoDestTelefono
						)
					select @idlotto,'',upper(col0),@IdCliente,GETDATE(),@IdProdotto
						,upper(col1),upper(col2),upper(col3),upper(col4),upper(col5)
						,@Cli_Ragionesociale,@Cli_Indirizzo,@Cli_cap,@Cli_Comune,@Cli_prov
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col3,null,@IdProdotto),dbo.GetCoperturaFiliale('G',col3,dbo.getbelfiore(col4,col5),@IdProdotto)
						,upper(col6),upper(col7)
						,upper(col8)
					from #tmpf
					order by #tmpf.id
				end

				--Comune di Sutera
				if @TipoFile=20
				begin
				
					--Elimino intestazione
					delete from #tmpf where col0='BARCODE'

					
					insert into SPED_ATTIVITA (IdLotto,TipoRiferimento,Barcode,IdCliente,DataCarico,IdProdotto
							,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneCap,DestinazioneLocalita,DestinazioneProvinciaCodice
							,NOTA1
							--,MittenteRagioneSociale,MittenteIndirizzo,mittenteCap,MittenteLocalita,mittenteprovinciacodice						
							,IdFiliale,IdFilialeDestinazione,IdFilialeGiacenza
							)
					select @idlotto,'',upper(col0),@IdCliente,GETDATE(),@IdProdotto
						,left(trim(upper(col1)),200),left(trim(upper(col2)),200),left(trim(upper(col3)),200),upper(col4),left(trim(upper(col5)),200)
						,col6
						,@IdFiliale,dbo.GetCoperturaFiliale('D',col3,null,3),dbo.GetCoperturaFiliale('G',col3,dbo.getbelfiore(col4,col5),3)						
					from #tmpf
						inner join PRODOTTI p on p.IdProdotto=@IdProdotto
					order by #tmpf.id
				end

				--inserisco  IdMittente
				update s set s.IdMittente=@idmittente
				from SPED_ATTIVITA s
				where s.IdLotto=@idlotto

				--se ADE Poste calcolo il listino giusto
				update sped_Attivita set idlistino=l.idlistino
				from  sped_Attivita sa
				left join fatt_listini l on l.idprodotto=sa.IdProdotto and l.idcliente=sa.idcliente
					and l.TipoArea=sa.nota1
					and sa.PortoPeso between convert(float,l.PesoMin) and convert(float,l.pesomax)
					and isnull(l.validodal,getdate())<=getdate()
					and isnull(l.validoal,getdate())>=getdate()  --260305 Carlo gestire la variazione di listino
				where sa.IdLotto=@idlotto and sa.idlistino is null

				--verifico se dispongo di Listino personalizzato
				set @Esito='Aggiornamento listino'
				update s set s.idListino=l.IdListino
				from SPED_ATTIVITA s
					inner join FATT_LISTINI l on l.IdProdotto=s.IdProdotto and s.IdCliente=l.IdCliente
					and isnull(l.validodal,getdate())<=getdate()
					and isnull(l.validoal,getdate())>=getdate()  --260305 Carlo gestire la variazione di listino
				where s.IdLotto=@idlotto and s.idlistino is null

				-- DISATTIVATO (agosto 2026): la funzione dbo.getlistinoconsip non esiste piu' su questo database.
				-- Calcolava il listino per i file CONSIP (TipoFile 14). Si commenta anche
				-- l'IF che la conteneva, altrimenti resterebbe senza istruzioni.
				-- Gli altri tipi di file non sono toccati: il listino lo assegna la query
				-- standard qui sopra.
				/*
				--se CONSIP il listino è calcolato in modo diverso
				if @TipoFile=14
						update SPED_ATTIVITA set idListino=dbo.getlistinoconsip(sa.idprodotto,CONVERT(int,sa.PortoPeso))							
						from SPED_ATTIVITA sa
						where sa.IdLotto=@idlotto
				*/

				--se IdFattListino è stato settato allora aggiorno il listino
				if isnull(@IdFattListino,0)<>0
				begin
					select @IdProdotto=@IdProdotto from FATT_LISTINI where IdListino=@IdFattListino
					update s set s.idListino=@IdFattListino,S.IdProdotto=@IdProdotto
					from SPED_ATTIVITA s 
					where s.IdLotto=@idlotto
				end

				--aggiorno il belfiore
				set @Esito='Aggiornamento Belfiore'

				update sped_attivita set belfiore=dbo.GetBelfiore(trim(sa.DestinazioneLocalita),trim(sa.DestinazioneProvinciaCodice))
				from SPED_ATTIVITA sa
				where 1=1
				and sa.belfiore is null
				and sa.IdLotto=@idlotto


				--correggo le filiali di ANCI
				update SPED_ATTIVITA set IdFiliale=36
				from SPED_ATTIVITA 
				where 1=1
				and IdCliente in (5363,5364)
				and IdLotto =@idlotto

				update SPED_ATTIVITA set IdFiliale=29
				from SPED_ATTIVITA 
				where 1=1
				and IdCliente in (5382)
				and IdLotto =@idlotto

				--aggiorno la datainserimento
				update SPED_ATTIVITA set DataInserimento=GETDATE()
				from SPED_ATTIVITA 
				where 1=1
				and DataInserimento is null


				if @codfamiglia='A'
				begin
					set @Esito='Aggiornamento Cod A'
					update SPED_ATTIVITA set 
						 RiferimentoEsterno3=isnull(riferimentoesterno3,'CAN41' + right('0000000000' + convert(varchar(20),idspedizione),10))
						,RiferimentoEsterno2=isnull(riferimentoesterno2,'CAD42' + right('0000000000' + convert(varchar(20),idspedizione),10))
						,RiferimentoEsterno1=isnull(riferimentoesterno1,'AGR46' + right('0000000000' + convert(varchar(20),idspedizione),10))
					where IdLotto=@idlotto
				end

				if @codfamiglia='N'
				begin
					set @Esito='Aggiornamento Cod N'
					update SPED_ATTIVITA set RiferimentoEsterno1=isnull(riferimentoesterno1,'RSN' + right('430000000000' + convert(varchar(20),idspedizione),12))
						,RiferimentoEsterno2=isnull(riferimentoesterno2,'RRD' + right('440000000000' + convert(varchar(20),idspedizione),12))
					where IdLotto=@idlotto
				end
				

				set @Esito='OK'
				commit transaction tr1
			end try
			begin catch
				rollback 
				set @Esito='Errore: '+ @esito + ' ' + ERROR_MESSAGE()
				raiserror (@Esito,16,1)
			end catch
	end	
			




		select @Esito as Result,@Idlotto as IdLotto
	end try

	begin catch
		set @Esito = ERROR_MESSAGE()
		select @Esito as Result,null as IdLotto

	end catch


END

