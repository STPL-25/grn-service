import sql from "mssql"; import { configDotenv } from "dotenv"; configDotenv({path:"E:/non_trade_new1/grn-service/.env",quiet:true});
const pool = await sql.connect({user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,server:process.env.SERVER,database:process.env.DATABASE,port:parseInt(process.env.DB_PORT)||1433,options:{trustServerCertificate:true}});
for (const q of process.argv.slice(2)) { try{const r = await pool.request().query(q); console.log(JSON.stringify(r.recordset));}catch(e){console.log("ERR",e.message)} }
await pool.close();
