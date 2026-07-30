/**
 * FTP upload helper for grn-service — mirrors backend/src/Utils/ImagesUpload/ImgUpload.js
 * so both services write to the same FTP server/paths. Kept as a small local
 * copy since grn-service is a separate deployable package from the monolith.
 */
import ftp from "basic-ftp";
import { Readable } from "stream";
import multer from "multer";
import { nanoid } from "nanoid";
import path from "path";

const memoryStorage = multer.memoryStorage();
export const upload = multer({ storage: memoryStorage, limits: { fileSize: 10 * 1024 * 1024 } });

const ftpConfig = {
  host: process.env.FTP_HOST || "10.0.222.102",
  user: process.env.FTP_USER || "1148",
  password: process.env.FTP_PASS || "$p@cek7m",
  secure: false,
};

class FtpUploader {
  constructor(config) {
    this.ftpConfig = config;
  }

  async uploadFile(fileBuffer, filename, subDirectory = "") {
    const client = new ftp.Client();
    client.ftp.verbose = false;
    try {
      await client.access(this.ftpConfig);

      if (subDirectory) {
        try {
          await client.cd(subDirectory);
        } catch {
          await client.send("MKD " + subDirectory);
          await client.cd(subDirectory);
        }
      }

      const fileStream = new Readable();
      fileStream.push(fileBuffer);
      fileStream.push(null);
      await client.uploadFrom(fileStream, filename);

      return { success: true };
    } catch (err) {
      return { success: false, message: `File upload failed: ${err.message}` };
    } finally {
      client.close();
    }
  }

  /** @param {Express.Multer.File} file @returns {Promise<string>} URL of the uploaded file, or "" */
  async uploadFileIfExists(file, subDirectory) {
    if (!file) return "";

    const fileExtension = path.extname(file.originalname);
    const baseName = path.basename(file.originalname, fileExtension);
    const uniqueFileName = `${baseName}_${nanoid(10)}${fileExtension}`;

    const result = await this.uploadFile(file.buffer, uniqueFileName, subDirectory);
    // The /dwl download route is mounted on the monolith backend (backend/src/Utils/ImagesUpload/imageRoute.js),
    // not on this service — point the URL there, not at grn-service's own SERVER_URL.
    const publicBase = process.env.BACKEND_PUBLIC_URL || "http://localhost:8081";
    return result.success
      ? `${publicBase}/dwl/${subDirectory}/${uniqueFileName}`
      : "";
  }
}

export const ftpUploader = new FtpUploader(ftpConfig);
