-- VideoCodifica (pagina /videocodifica): salvataggio di una riga corretta a video.
-- La chiusura del lotto resta alla stored legacy dbo.Lotto_VideoCodifica (genera i
-- barcode mancanti, valida destinatari/CAP/province, marca DataVideoCodifica e
-- porta tutto in maiuscolo); qui si aggiornano solo i campi editabili della
-- spedizione, e solo finche' il lotto non e' stato videocodificato.
CREATE OR ALTER PROCEDURE dbo.AI_SPED_VideoCodifica_Save
    @IdSpedizione int,
    @Barcode varchar(50) = NULL,
    @Destinatario varchar(200) = NULL,
    @Indirizzo varchar(200) = NULL,
    @Civico varchar(200) = NULL,
    @Localita varchar(200) = NULL,
    @Cap varchar(5) = NULL,
    @Prov varchar(2) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.SPED_ATTIVITA s
                   INNER JOIN dbo.SPED_LOTTI l ON l.IdLotto = s.IdLotto
                   WHERE s.IdSpedizione = @IdSpedizione
                     AND l.DataVideoCodifica IS NULL AND l.DataAnnullamento IS NULL)
    BEGIN
        SELECT 'Spedizione inesistente o lotto gia'' videocodificato' AS Result;
        RETURN;
    END

    UPDATE dbo.SPED_ATTIVITA SET
        Barcode = NULLIF(LTRIM(RTRIM(ISNULL(@Barcode, ''))), ''),
        DestinazioneRagioneSociale = NULLIF(LTRIM(RTRIM(ISNULL(@Destinatario, ''))), ''),
        DestinazioneIndirizzo = NULLIF(LTRIM(RTRIM(ISNULL(@Indirizzo, ''))), ''),
        DestinazioneNumeroCivico = NULLIF(LTRIM(RTRIM(ISNULL(@Civico, ''))), ''),
        DestinazioneLocalita = NULLIF(LTRIM(RTRIM(ISNULL(@Localita, ''))), ''),
        DestinazioneCap = NULLIF(LTRIM(RTRIM(ISNULL(@Cap, ''))), ''),
        DestinazioneProvinciaCodice = UPPER(NULLIF(LTRIM(RTRIM(ISNULL(@Prov, ''))), ''))
    WHERE IdSpedizione = @IdSpedizione;

    SELECT 'OK' AS Result;
END
GO
GRANT EXECUTE ON dbo.AI_SPED_VideoCodifica_Save TO claude;
-- stored legacy usate dalle pagine VideoCodifica e Checkin Lotti
GRANT EXECUTE ON dbo.Lotto_VideoCodifica TO claude;
GRANT EXECUTE ON dbo.FORM_CHECKIN TO claude;
GRANT EXECUTE ON dbo.Lotto_Checkin TO claude;
