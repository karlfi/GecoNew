-- Upsert generato dallo schema di [MITTENTI]. Scritture solo via SP (prefisso AI_).
-- Nota: la tabella non ha PK dichiarata; la chiave logica e' l'identity IdMittente.
-- Nota: la colonna [CODICE_FISCALE ] ha uno SPAZIO finale nel nome (legacy). Il parametro
--       e' @CODICE_FISCALE (senza spazio, il backend fa TrimEnd sui nomi); la colonna
--       viene referenziata con le parentesi quadre comprensive dello spazio.
CREATE OR ALTER PROCEDURE dbo.AI_MITTENTI_Save
    @IdMittente int = NULL,
    @UFFICIOSPEDITORE varchar(250) = NULL,
    @FILIALECOMPETENZA varchar(250) = NULL,
    @COMUNE varchar(250) = NULL,
    @PROV varchar(2) = NULL,
    @INDIRIZZO varchar(250) = NULL,
    @NOTE1 varchar(250) = NULL,
    @CAP varchar(250) = NULL,
    @NOTE2 varchar(250) = NULL,
    @NomeControlloReportistica varchar(250) = NULL,
    @EmailControlloReportistica varchar(250) = NULL,
    @Telefonocontrolloreportistica varchar(250) = NULL,
    @NomeControlloReportistica2 varchar(250) = NULL,
    @EmailControlloReportistica2 varchar(250) = NULL,
    @Telefonocontrolloreportistica2 varchar(250) = NULL,
    @CODICE_FISCALE varchar(250) = NULL,
    @CODICE_UNIVOCO varchar(250) = NULL,
    @idFilialeDistribuzione int = NULL,
    @idCliente int = NULL,
    @LU int = NULL,
    @MA int = NULL,
    @ME int = NULL,
    @GI int = NULL,
    @VE int = NULL,
    @SA int = NULL,
    @idStpRepFunz int = NULL,
    @email_mittente varchar(250) = NULL,
    @Responsabile_operativo varchar(250) = NULL,
    @Email_operativa varchar(250) = NULL,
    @Resp_amministrativo varchar(250) = NULL,
    @Email_amministrativo varchar(250) = NULL,
    @idUfficioMitt int = NULL,
    @DescScontrino varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @IdMittente IS NULL OR @IdMittente = 0
    BEGIN
        INSERT INTO [MITTENTI] ([UFFICIOSPEDITORE], [FILIALECOMPETENZA], [COMUNE], [PROV], [INDIRIZZO], [NOTE1], [CAP], [NOTE2], [NomeControlloReportistica], [EmailControlloReportistica], [Telefonocontrolloreportistica], [NomeControlloReportistica2], [EmailControlloReportistica2], [Telefonocontrolloreportistica2], [CODICE_FISCALE ], [CODICE_UNIVOCO], [idFilialeDistribuzione], [idCliente], [LU], [MA], [ME], [GI], [VE], [SA], [idStpRepFunz], [email_mittente], [Responsabile_operativo], [Email_operativa], [Resp_amministrativo], [Email_amministrativo], [idUfficioMitt], [DescScontrino])
        VALUES (@UFFICIOSPEDITORE, @FILIALECOMPETENZA, @COMUNE, @PROV, @INDIRIZZO, @NOTE1, @CAP, @NOTE2, @NomeControlloReportistica, @EmailControlloReportistica, @Telefonocontrolloreportistica, @NomeControlloReportistica2, @EmailControlloReportistica2, @Telefonocontrolloreportistica2, @CODICE_FISCALE, @CODICE_UNIVOCO, @idFilialeDistribuzione, @idCliente, @LU, @MA, @ME, @GI, @VE, @SA, @idStpRepFunz, @email_mittente, @Responsabile_operativo, @Email_operativa, @Resp_amministrativo, @Email_amministrativo, @idUfficioMitt, @DescScontrino);
        SELECT CAST(SCOPE_IDENTITY() AS int) AS id;
    END
    ELSE
    BEGIN
        UPDATE [MITTENTI] SET
            [UFFICIOSPEDITORE] = @UFFICIOSPEDITORE,
            [FILIALECOMPETENZA] = @FILIALECOMPETENZA,
            [COMUNE] = @COMUNE,
            [PROV] = @PROV,
            [INDIRIZZO] = @INDIRIZZO,
            [NOTE1] = @NOTE1,
            [CAP] = @CAP,
            [NOTE2] = @NOTE2,
            [NomeControlloReportistica] = @NomeControlloReportistica,
            [EmailControlloReportistica] = @EmailControlloReportistica,
            [Telefonocontrolloreportistica] = @Telefonocontrolloreportistica,
            [NomeControlloReportistica2] = @NomeControlloReportistica2,
            [EmailControlloReportistica2] = @EmailControlloReportistica2,
            [Telefonocontrolloreportistica2] = @Telefonocontrolloreportistica2,
            [CODICE_FISCALE ] = @CODICE_FISCALE,
            [CODICE_UNIVOCO] = @CODICE_UNIVOCO,
            [idFilialeDistribuzione] = @idFilialeDistribuzione,
            [idCliente] = @idCliente,
            [LU] = @LU,
            [MA] = @MA,
            [ME] = @ME,
            [GI] = @GI,
            [VE] = @VE,
            [SA] = @SA,
            [idStpRepFunz] = @idStpRepFunz,
            [email_mittente] = @email_mittente,
            [Responsabile_operativo] = @Responsabile_operativo,
            [Email_operativa] = @Email_operativa,
            [Resp_amministrativo] = @Resp_amministrativo,
            [Email_amministrativo] = @Email_amministrativo,
            [idUfficioMitt] = @idUfficioMitt,
            [DescScontrino] = @DescScontrino
        WHERE [IdMittente] = @IdMittente;
        SELECT @IdMittente AS id;
    END
END
