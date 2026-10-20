import sql from "mssql"; import {configDotenv} from "dotenv"; configDotenv();
const p=await sql.connect({server:process.env.SERVER,database:process.env.DATABASE,user:process.env.DB_USER,password:process.env.DB_USER_PASSWORD,options:{encrypt:false,trustServerCertificate:true}});
for (const q of process.argv.slice(2)) { try{const r=await p.request().query(q);console.log(JSON.stringify(r.recordset,null,0));}catch(e){console.log('ERR',e.message)} }
process.exit(0)
