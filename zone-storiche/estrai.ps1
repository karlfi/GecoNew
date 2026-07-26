# credenziali dalla variabile d'ambiente DELIVERYDB_CS, es.:
#   $env:DELIVERYDB_CS = "Server=...;Database=DeliveryDB;User Id=...;Password=...;Encrypt=False"
$cs = $env:DELIVERYDB_CS
if (-not $cs) { throw "Impostare la variabile d'ambiente DELIVERYDB_CS con la connection string" }
$cn = New-Object System.Data.SqlClient.SqlConnection $cs
$cn.Open()
$cmd = $cn.CreateCommand()
$cmd.CommandTimeout = 300
$cmd.CommandText = @"
SELECT Postino, CONVERT(varchar(10), DataRecapito, 120) AS giorno, Latitudine, Longitudine
FROM Speedy.dbo.NEXIVE_Consegne
WHERE Filiale = 'GROSSETO_2'
  AND DataRecapito >= '20191101' AND DataRecapito < '20200401'
  AND Latitudine IS NOT NULL AND Longitudine IS NOT NULL AND Latitudine <> 0
"@
$rd = $cmd.ExecuteReader()
$sw = New-Object System.IO.StreamWriter("C:\Users\Carlo\AppData\Local\Temp\claude\C--progetti-AI-TWEB\53fa87f8-62f2-4876-98a8-b6325d6172f6\scratchpad\grosseto.csv", $false, [System.Text.Encoding]::UTF8)
$sw.WriteLine("postino,giorno,lat,lng")
$ci = [System.Globalization.CultureInfo]::InvariantCulture
$n = 0
while ($rd.Read()) {
  $sw.WriteLine(('{0},{1},{2},{3}' -f $rd.GetString(0), $rd.GetString(1), $rd.GetDouble(2).ToString($ci), $rd.GetDouble(3).ToString($ci)))
  $n++
}
$sw.Close(); $cn.Close()
"righe estratte: $n"
