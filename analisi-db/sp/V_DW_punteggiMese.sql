
CREATE VIEW [dbo].[V_DW_punteggiMese]
AS
SELECT TOP (100) PERCENT IDFILIALE, SUM(Punteggio) AS Punteggio
, right(convert(varchar(4),anno),2) + '-'+right('00'+convert(varchar(3),Mese),2) as mese, Anno, SUM(CASE WHEN Punteggio > 0 THEN 1 ELSE 0 END) AS Giornate, CONVERT(int, SUM(Punteggio) / SUM(CASE WHEN Punteggio > 0 THEN 1 ELSE 0 END)) AS Media
FROM  dbo.V_UtentiAttivita2024
WHERE (1 = 1) AND (Data >= DATEADD(month, - 10, GETDATE()))
GROUP BY Filiale, IDFILIALE, Mese, Anno
ORDER BY Anno, Mese

